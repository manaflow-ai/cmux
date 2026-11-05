import CmuxNextPages
import CmuxNextSettings

/// What the host's own first open of a tab answered: the source it opened, and the answer.
nonisolated struct DiffPreopened: Sendable {
    let source: JSONValue?
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
        preopen = Task { [self] in
            guard let tab = try? await ready.value, let source = tab.config["payload"]?["sessionSource"], source != .null else {
                return DiffPreopened(source: nil, result: .failure(CancellationError()))
            }
            // Precomputed when an agent's turn ended (DiffPageRuntime+Warm.swift): the session is open already.
            if let warm = tab.warm {
                if let id = Self.openedSession(warm.result) { sessions.insert(id) }
                mark("diff.warm")
                return DiffPreopened(source: source, result: .success(Self.prepared(warm.result, "warm", fingerprint: warm.fingerprint)))
            }
            mark("diff.preopen")
            do {
                let result = try await open(["source": source, "capabilityToken": .string(tab.grant.token)], tab: tab)
                mark("diff.preopened")
                return DiffPreopened(source: source, result: .success(Self.prepared(result, "preopen")))
            } catch {
                return DiffPreopened(source: source, result: .failure(error))
            }
        }
    }

    /// The pre-opened answer when the page asks for the same source with no other option (Hide white
    /// space asks for another diff), else nil and the pre-opened session is closed. A pre-open that
    /// failed for that source (no changes, no base) answers with its error, so the page gets it without
    /// a second run; one that was cancelled opens again.
    func takePreopened(matching params: [String: JSONValue], grant: DiffSessionGrant) async throws -> JSONValue? {
        guard let task = preopen else { return nil }
        preopen = nil
        let opened = await task.value
        let same = opened.source != nil && opened.source == params["source"] && params["ignoreWhitespace"]?.boolValue != true
        switch opened.result {
        case .success(let result):
            if same { return result }
            if let id = Self.openedSession(result) { await closeQuietly(id, grant: grant) }
            return nil
        case .failure(let error):
            if same, !Self.isCancellation(error) { throw error }
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

    nonisolated static func isCancellation(_ error: any Error) -> Bool {
        error is CancellationError || (error as? PageError)?.code == "cancelled"
    }
}
