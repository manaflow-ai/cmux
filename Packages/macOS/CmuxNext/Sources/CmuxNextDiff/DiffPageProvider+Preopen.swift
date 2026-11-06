import CmuxNextPages
import CmuxNextSettings

/// What the host's own first open of a tab answered: the source it opened, and the answer.
nonisolated struct DiffPreopened: Sendable {
    let source: JSONValue?
    /// Whether it asked the sidecar to leave white space changes out (the Hide white space setting).
    var ignoreWhitespace = false
    let result: Result<JSONValue, any Error>
}

/// The tab's first session opens while its page boots (Leo, 2026-11-05: "There's no reason for them
/// to have a delay, even under load."). Before, the page loaded, asked its config and language pack,
/// rendered, and only then asked `sessionOpen`, so the sidecar's start and its `git diff` waited for
/// the whole page boot. Now the host starts that same open as soon as the tab's grant is ready, and the
/// page's first `sessionOpen` for the same source takes its answer, usually already there. As Chrome
/// starts a navigation's network request before the renderer is ready (the browser process, not the
/// page, issues it), the open runs beside the page instead of after it.
extension DiffPageProvider {
    /// Opens the config's source now; the page's matching `sessionOpen` takes the answer
    /// (``takePreopened(matching:grant:)``). Nothing for a chat patch tab, a remote tab (its git is a
    /// daemon read the page starts) or a tab with no repository yet.
    public func startPreopen() {
        guard preopen == nil, let ready, !chatPatch, !remote, !isClosed else { return }
        // task-owner: the tab's first session open; the page's first sessionOpen takes it, retire() cancels it
        // The page asks for white space left out when the setting is on and the sidecar offers it.
        let hideWhitespace = stores?.prefs.prefs()["hideWhitespace"]?.boolValue == true
        preopen = Task { [self] in
            let cancelled = DiffPreopened(source: nil, result: .failure(CancellationError()))
            guard let tab = try? await ready.value, let source = tab.config["payload"]?["sessionSource"], source != .null else {
                return cancelled
            }
            // Retired (another folder, the tab closed) while the grant was made: open nothing on it.
            guard !Task.isCancelled, self.ready == ready, !isClosed else { return cancelled }
            let ignoreWhitespace = hideWhitespace && Self.offersIgnoreWhitespace(tab.config)
            // Precomputed when an agent's turn ended (DiffPageRuntime+Warm.swift): the session is open already.
            if let warm = tab.warm {
                if let id = Self.openedSession(warm.result) { sessions.insert(id) }
                mark("diff.warm")
                return DiffPreopened(source: source, result: .success(Self.prepared(warm.result, "warm", fingerprint: warm.fingerprint)))
            }
            mark("diff.preopen")
            var params: [String: JSONValue] = ["source": source, "capabilityToken": .string(tab.grant.token)]
            if ignoreWhitespace { params["ignoreWhitespace"] = true }
            do {
                let result = try await open(params, tab: tab)
                mark("diff.preopened")
                return DiffPreopened(source: source, ignoreWhitespace: ignoreWhitespace, result: .success(Self.prepared(result, "preopen")))
            } catch {
                return DiffPreopened(source: source, ignoreWhitespace: ignoreWhitespace, result: .failure(error))
            }
        }
    }

    /// The pre-opened answer when the page asks for the same source and the same Hide white space
    /// choice, else nil and the pre-opened session is closed. A pre-open that found no changes for that
    /// source answers with that, so the page gets it without a second run; any other failure (a busy
    /// or missing sidecar, a cancel) opens again.
    func takePreopened(matching params: [String: JSONValue], grant: DiffSessionGrant) async throws -> JSONValue? {
        guard let task = preopen else { return nil }
        preopen = nil
        let opened = await task.value
        let same = opened.source != nil && opened.source == params["source"]
            && (params["ignoreWhitespace"]?.boolValue == true) == opened.ignoreWhitespace
        switch opened.result {
        case .success(let result):
            if same { return result }
            if let id = Self.openedSession(result) { await closeQuietly(id, grant: grant) }
            return nil
        case .failure(let error):
            if same, (error as? PageError)?.code == "emptyDiff" { throw error }
            return nil
        }
    }

    /// `result` (a `sessionOpened`) saying how the host had it ready: `prepared` ("preopen", "warm")
    /// and, for a precomputed one, the fingerprint it had (the page's freshness baseline).
    nonisolated static func prepared(_ result: JSONValue, _ how: String, fingerprint: String? = nil) -> JSONValue {
        guard case .object(var members) = result, case .object(var value)? = members["value"] else { return result }
        value["prepared"] = .string(how)
        if let fingerprint { value["fingerprint"] = .string(fingerprint) }
        members["value"] = .object(value)
        return .object(members)
    }

    /// Whether the tab's sidecar takes `ignoreWhitespace` (the page asks for it only then).
    nonisolated static func offersIgnoreWhitespace(_ config: JSONValue) -> Bool {
        config["payload"]?["sessionCapabilities"]?.arrayValue?.contains("session.ignoreWhitespace") == true
    }
}
