public import CmuxNextPages
public import CmuxNextSettings
public import CmuxNextAgentPane
public import Foundation

/// One diff tab's `cmux.diff.*` namespace (diff-host.md decision a): the page
/// calls `cmux.diff.<sidecar method>` with the request's params and gets its
/// `DiffResult`. The provider owns the tab's session state:
/// - every request carries this tab's capability token (and branch group),
///   whatever the page sent, so a tab only ever acts as itself;
/// - it names each new session itself, so a superseded or abandoned open can
///   still be closed, and it closes only sessions it opened;
/// - a tab with no repository answers `{pick: true}` until `cmux.diff.open`
///   (or a folder dropped on it) gives it one; a new repository retires the
///   old grant and its sessions;
/// - ``close()`` stops the open in flight, closes every session and removes
///   the grant.
/// The stdio sidecar sends no events: `cmux.diff.events` subscribes and stays
/// quiet until the sidecar becomes a pane-protocol provider.
public final class DiffPageProvider: PageProvider {
    static let methods: Set<String> = [
        "protocolHandshake", "sessionOpen", "sessionClose", "branchList", "branchChange", "fileContents",
    ]
    static let configOp = "cmux.diff.config"
    static let languagesOp = "cmux.diff.languages"
    static let eventsStream = "cmux.diff.events"
    static let recentsOp = "cmux.diff.recents"
    static let chooseFolderOp = "cmux.diff.chooseFolder"
    static let openOp = "cmux.diff.open"
    static let notARepository = "cmux.diff.not_a_repo"
    /// A repository on another machine that cannot answer now (the page shows the message).
    static let machineOffline = "cmux.diff.machine_offline"
    /// The id the page closes before its first open has answered.
    static let pendingSessionID = "00000000-0000-0000-0000-000000000000"
    static let maximumRequestBytes = 1024 * 1024

    /// The tab's repository grant, nil while it shows the empty state.
    public private(set) var ready: Task<DiffTabReady, any Error>?
    private let sidecar: (any DiffSidecarRunning)?
    private let languages: DiffLanguageFeed?
    let remote: Bool
    /// The name of the machine a remote tab's repository is on (#25581, a Cloud workspace's), for
    /// the page's offline message; nil for this Mac and for a remote chat's tab.
    public let machine: String?
    private(set) weak var host: (any DiffTabHosting)?
    /// Prefs and viewed marks (``DiffPageStores``); nil serves no store op.
    let stores: DiffPageStores?
    /// Stage, Commit and Push in the tab's repository (``DiffGitRunning``); nil serves no git op.
    let git: (any DiffGitRunning)?
    /// Asks before Revert throws work away (DiffPageProvider+Revert.swift); nil reverts no file.
    public var confirmRevert: DiffRevertConfirming?
    /// The hunks Undo can put back, and the gesture the last revert spent.
    var revertState = DiffRevertState()
    /// Sessions of the current grant this tab named or was given, not closed yet.
    private(set) var sessions: Set<String> = []
    private var opening: (session: String, task: Task<JSONValue, any Error>)?
    private var discards: [Task<Void, Never>] = []
    private var events: [UUID: (JSONValue) -> Void] = [:]
    /// Sessions materialized from a remote daemon, keyed by the provider's session id.
    private var remoteSessions: [String: RemoteSession] = [:]
    private(set) var isClosed = false
    /// The gesture (`systemUptime`) the last `cmux.diff.openFile` spent (DiffPageProvider+Open.swift).
    var spentOpenGesture: TimeInterval?

    private struct RemoteSession {
        let source: JSONValue
        let scope: AgentPaneGitScope
        let files: [JSONValue]
    }

    private static let remoteHandshake: JSONValue = [
        "type": "handshake", "value": ["protocolVersion": 1, "capabilities": ["session.fileContents"]],
    ]
    private static let remoteFullFileContextLines = 100_000

    public init(ready: Task<DiffTabReady, any Error>?, sidecar: (any DiffSidecarRunning)?, languages: DiffLanguageFeed?,
         host: (any DiffTabHosting)? = nil, stores: DiffPageStores? = nil, git: (any DiffGitRunning)? = nil,
         machine: String? = nil) {
        self.ready = ready
        self.machine = machine
        self.stores = stores
        self.git = git
        self.sidecar = sidecar
        self.languages = languages
        self.host = host
        remote = git?.isRemote == true
    }

    /// The tab shows the empty state (no repository yet).
    public var isPicking: Bool { ready == nil && !isClosed }

    public func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        guard !isClosed else { throw PageError.closed }
        switch op {
        case Self.configOp:
            return try await config()
        case Self.languagesOp:
            guard let languages else { throw PageError.unknownOp(op) }
            return await languages.pack()
        case Self.recentsOp:
            // This Mac's folders: a tab of another machine's repository picks none of them.
            guard let host, !remote else { throw PageError.unknownOp(op) }
            return await host.recents()
        case Self.chooseFolderOp:
            guard let host, !remote else { throw PageError.unknownOp(op) }
            let start = params["start"]?.stringValue.map { URL(fileURLWithPath: $0, isDirectory: true) }
            return await host.chooseFolder(start: start).map { ["path": .string($0.path)] } ?? .null
        case Self.openOp:
            guard let path = params["path"]?.stringValue, path.hasPrefix("/") else { throw PageError.invalidParams("path is required") }
            return try await open(folder: URL(fileURLWithPath: path, isDirectory: true), source: DiffOpenSource(page: params["source"]))
        default:
            if let value = try await storeCall(op, params: params) { return value }
            if let value = try await gitCall(op, params: params, context: context) { return value }
            if let value = try await revertCall(op, params: params, context: context) { return value }
            if let value = try await openFileCall(op, params: params, context: context) { return value }
            let method = String(op.dropFirst("cmux.diff.".count))
            guard op.hasPrefix("cmux.diff."), Self.methods.contains(method) else { throw PageError.unknownOp(op) }
            return try await request(method, params: params.objectValue ?? [:])
        }
    }

    public func subscribe(_ stream: String, filter: JSONValue, context: PageCallContext,
                   onEvent: @escaping @MainActor (JSONValue) -> Void) async throws -> PageSubscription {
        guard !isClosed else { throw PageError.closed }
        switch stream {
        case Self.eventsStream:
            let id = UUID()
            events[id] = onEvent
            return PageSubscription { [weak self] in self?.events[id] = nil }
        case Self.languagesOp:
            guard let languages else { throw PageError.unknownOp(stream) }
            let stop = languages.listen(onEvent)
            return PageSubscription { stop() }
        case Self.prefsStream:
            guard let stores else { throw PageError.unknownOp(stream) }
            let stop = stores.prefs.listen { prefs in onEvent(["prefs": .object(prefs)]) }
            return PageSubscription { stop() }
        default:
            throw PageError.unknownOp(stream)
        }
    }

    private func config() async throws -> JSONValue {
        guard let ready else { return await withStores(["pick": true]) }
        do {
            let tab = try await ready.value
            // A turn the tab got after its grant (the header's Changes) is offered as Last turn too.
            let config = tab.turn == nil && host?.turn(for: tab.grant.repository) != nil
                ? DiffPageConfig.offeringTurn(tab.config) : tab.config
            var served = withOpenFile(withGit(await withStores(config)))
            if remote { served = Self.withoutRemoteWhitespace(served) }
            return served
        } catch let failure as DiffTabFailure {
            return DiffPageConfig.failure(title: failure.title, message: failure.message)
        }
    }

    private static func withoutRemoteWhitespace(_ config: JSONValue) -> JSONValue {
        guard case .object(var members) = config, case .object(var payload)? = members["payload"],
              let capabilities = payload["sessionCapabilities"]?.arrayValue else { return config }
        payload["sessionCapabilities"] = .array(capabilities.filter { $0.stringValue != "session.ignoreWhitespace" })
        members["payload"] = .object(payload)
        return .object(members)
    }

    /// Shows the repository `folder` is in, from `source` (`cmux.diff.open`, a
    /// dropped folder): the config the page renders in place. The previous
    /// grant, its sessions and files are retired first.
    public func open(folder: URL, source: DiffOpenSource) async throws -> JSONValue {
        guard !isClosed else { throw PageError.closed }
        guard let host else { throw PageError.unknownOp(Self.openOp) }
        guard let repository = await host.repository(at: folder) else {
            throw PageError(code: Self.notARepository, message: folder.path)
        }
        await retire()
        guard !isClosed else { throw PageError.closed }
        ready = host.prepare(repository, source: source)
        host.opened(repository, source: source)
        return try await config()
    }

    // MARK: Requests

    private func request(_ method: String, params: [String: JSONValue]) async throws -> JSONValue {
        guard let ready else { throw PageError(code: "sidecarUnavailable", message: "No repository is open") }
        let tab: DiffTabReady
        do {
            tab = try await ready.value
        } catch let failure as DiffTabFailure {
            throw PageError(code: "sidecarUnavailable", message: failure.message)
        }
        let grant = tab.grant
        var params = params
        params["capabilityToken"] = .string(grant.token)
        switch method {
        case "protocolHandshake":
            if remote { return Self.remoteHandshake }
            return try await send(method, params: nil)
        case "sessionOpen":
            return try await open(params, tab: tab)
        case "sessionClose":
            guard let id = params["sessionId"]?.stringValue else { throw PageError.invalidParams("sessionId is required") }
            if id == Self.pendingSessionID {
                stopOpening(grant: grant)
                return ["type": "sessionClosed"]
            }
            guard sessions.contains(id) else { throw PageError(code: "notAllowed", message: "Diff session is not authorized") }
            if remote {
                remoteSessions[id] = nil
                sessions.remove(id)
                return ["type": "sessionClosed"]
            }
            let result = try await send(method, params: params)
            sessions.remove(id)
            return result
        case "fileContents":
            // A file's two sides (Load full files, Rich preview): only for one of this tab's
            // sessions; the sidecar also checks the token owns it and its patch names the path.
            guard let id = params["sessionId"]?.stringValue, sessions.contains(id) else {
                throw PageError(code: "notAllowed", message: "Diff session is not authorized")
            }
            if remote { return try await remoteFileContents(params, tab: tab) }
            return try await send(method, params: params)
        case "branchChange":
            if remote { return try await remoteBranchChange(params, tab: tab) }
            params["groupId"] = .string(grant.group)
            let result = try await send(method, params: params)
            if let id = Self.openedSession(result) { sessions.insert(id) }
            return result
        default:
            if remote { return try await remoteRequest(method, params: params, tab: tab) }
            return try await send(method, params: params)
        }
    }

    /// A new open replaces the one in flight (the page shows one session). Last turn first
    /// writes the chat turn's patch, read from the session host, inside the same open, so a newer
    /// pick stops it as it stops any open.
    private func open(_ params: [String: JSONValue], tab: DiffTabReady) async throws -> JSONValue {
        let grant = tab.grant
        stopOpening(grant: grant)
        let id = UUID().uuidString.lowercased()
        var params = params
        params["sessionId"] = .string(id)
        sessions.insert(id)
        // The chat's turn now (the header gives a tab a newer one), else the one the tab opened with.
        let turnPatch = DiffTurnPatch.opens(params), turn = host?.turn(for: grant.repository) ?? tab.turn
        let task = Task { [self] in
            if turnPatch && !remote {
                try await writeTurnPatch(turn, in: grant)
                try Task.checkCancellation()
            }
            if remote { return try await remoteSessionOpen(params, tab: tab) }
            return try await send("sessionOpen", params: params)
        }
        opening = (id, task)
        defer { if opening?.session == id { opening = nil } }
        let result = try await task.value
        // A patch session (Last turn) gets the sidecar's own id, which the page then closes.
        if let opened = Self.openedSession(result) { sessions.insert(opened) }
        return result
    }

    /// A remote read that got no answer names the machine (#25581); the session host's own
    /// refusals keep their code.
    func remoteError(_ failure: AgentPaneGitFailure) -> PageError {
        guard let machine, failure == .notConnected || failure == .timedOut else { return Self.pageError(failure) }
        return PageError(code: Self.machineOffline, message: DiffPageStrings.machineOffline(machine), retryable: true)
    }

    /// A remote daemon has no local sidecar. Its git result is materialized into
    /// this tab's patch grant, while the session response stays sidecar-shaped.
    private func remoteSessionOpen(_ params: [String: JSONValue], tab: DiffTabReady) async throws -> JSONValue {
        guard let git else { throw PageError(code: "remoteUnavailable", message: "The remote git service is unavailable") }
        guard let source = params["source"] else { throw PageError.invalidParams("source is required") }
        let scope: AgentPaneGitScope
        let diff: JSONValue
        if source["kind"]?.stringValue == "patch" {
            guard let turn = host?.turn(for: tab.grant.repository) ?? tab.turn else {
                throw PageError(code: "notAllowed", message: "This remote diff has no chat turn")
            }
            do {
                diff = try await git.checkpointDiff(tab.grant.repository, from: turn.from, to: turn.to)
            } catch { throw remoteError(error) }
            scope = .uncommitted
        } else {
            switch source["kind"]?.stringValue {
            case "staged": scope = .staged
            case "unstaged": scope = .unstaged
            case "branch": scope = source["baseRef"]?.stringValue == "HEAD" ? .uncommitted : .branch
            default: throw PageError.invalidParams("unsupported remote diff source")
            }
            do {
                diff = try await git.diff(tab.grant.repository, scope: scope, includePatch: true)
            } catch { throw remoteError(error) }
        }
        let files = diff["files"]?.arrayValue ?? []
        guard !files.isEmpty else { throw PageError(code: "emptyDiff", message: "No changes to diff") }
        let patch: String
        if source["kind"]?.stringValue == "patch" {
            patch = DiffTurnPatch.make(diff)
            try await Self.writeTurnPatch(patch, to: tab.grant)
        } else {
            patch = DiffTurnPatch.make(diff)
            try await Self.writeRemotePatch(patch, to: tab.grant)
        }
        let sessionID = params["sessionId"]?.stringValue ?? UUID().uuidString.lowercased()
        remoteSessions[sessionID] = RemoteSession(source: source, scope: scope, files: files)
        return Self.sessionOpened(sessionID: sessionID, source: source, requestPath: source["kind"]?.stringValue == "patch" ? DiffTurnPatch.requestPath : DiffSessionGrant.remotePatchRequestPath,
                                  token: tab.grant.token, byteLength: patch.utf8.count)
    }

    private func remoteBranchChange(_ params: [String: JSONValue], tab: DiffTabReady) async throws -> JSONValue {
        var next = params
        next["source"] = ["kind": "branch", "repoRoot": .string(tab.grant.repository),
                           "baseRef": params["baseRef"] ?? .null]
        return try await remoteSessionOpen(next, tab: tab)
    }

    private func remoteRequest(_ method: String, params: [String: JSONValue], tab: DiffTabReady) async throws -> JSONValue {
        switch method {
        case "branchList":
            return ["type": "branches", "value": ["groups": []]]
        default:
            throw PageError(code: "remoteUnsupported", message: "The remote diff service does not support \(method)")
        }
    }

    private func remoteFileContents(_ params: [String: JSONValue], tab: DiffTabReady) async throws -> JSONValue {
        guard let git, let id = params["sessionId"]?.stringValue, let session = remoteSessions[id],
              let path = params["path"]?.stringValue, Self.isRepositoryPath(path) else {
            throw PageError(code: "notAllowed", message: "Diff session is not authorized")
        }
        let scope = session.scope
        let previous = params["previousPath"]?.stringValue
        guard session.files.contains(where: { file in
            file["path"]?.stringValue == path || file["previous_path"]?.stringValue == path || file["path"]?.stringValue == previous
        }) else { throw PageError(code: "notAllowed", message: "The file is not in this diff") }
        let diff: JSONValue
        do {
            diff = try await git.diff(tab.grant.repository, scope: scope, includePatch: true,
                                      options: AgentPaneGitDiffOptions(paths: [path], contextLines: Self.remoteFullFileContextLines))
        } catch { throw remoteError(error) }
        guard let file = diff["files"]?.arrayValue?.first(where: { $0["path"]?.stringValue == path }) else {
            throw PageError(code: "remoteFileUnavailable", message: "The remote file is no longer in this diff")
        }
        guard file["patch_truncated"]?.boolValue != true, let patch = file["patch"]?.stringValue,
              let sides = Self.remoteSides(patch, status: file["status"]?.stringValue ?? "modified",
                                            contextLimit: Self.remoteFullFileContextLines) else {
            return ["type": "fileContents", "value": ["tooLarge": true]]
        }
        var value: [String: JSONValue] = [:]
        if let old = sides.old { value["old"] = ["contents": .string(old), "encoding": "text"] }
        if let new = sides.new { value["new"] = ["contents": .string(new), "encoding": "text"] }
        return ["type": "fileContents", "value": .object(value)]
    }

    private static func sessionOpened(sessionID: String, source: JSONValue, requestPath: String, token: String, byteLength: Int) -> JSONValue {
        ["type": "sessionOpened", "value": ["sessionId": .string(sessionID), "source": source,
          "patch": ["id": .string("cmux-page://cmux.diff/__patch/\(token)\(requestPath)"),
                     "mediaType": .string(DiffPatchResolver.mimeType), "byteLength": .number(Double(byteLength)), "revision": 1],
          "generatedPaths": []]]
    }

    private static func writeTurnPatch(_ patch: String, to grant: DiffSessionGrant) async throws {
        try await Task.detached(priority: .userInitiated) { try grant.writeTurnPatch(patch) }.value
    }

    private static func writeRemotePatch(_ patch: String, to grant: DiffSessionGrant) async throws {
        try await Task.detached(priority: .userInitiated) { try grant.writeRemotePatch(patch) }.value
    }

    private static func isRepositoryPath(_ path: String) -> Bool {
        !path.isEmpty && path.utf8.count <= 4096 && !path.hasPrefix("/") && !path.contains("\u{0}")
            && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private static func remoteSides(_ patch: String, status: String, contextLimit: Int) -> (old: String?, new: String?)? {
        guard patch.contains("@@") else { return nil }
        var old = "", new = ""
        var inHunk = false
        var expectedOld = 0, expectedNew = 0
        var seenOld = 0, seenNew = 0
        var leadingContext = 0, trailingContext = 0
        var changed = false
        for line in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = String(line)
            if text.hasPrefix("@@ ") {
                if inHunk && (seenOld != expectedOld || seenNew != expectedNew) { return nil }
                if inHunk && (leadingContext >= contextLimit || trailingContext >= contextLimit) { return nil }
                guard let counts = hunkCounts(text) else { return nil }
                expectedOld = counts.old
                expectedNew = counts.new
                seenOld = 0
                seenNew = 0
                leadingContext = 0
                trailingContext = 0
                changed = false
                inHunk = true
                continue
            }
            guard inHunk else { continue }
            guard let first = line.first else { continue }
            if first == "\\" { continue }
            guard first == " " || first == "-" || first == "+" else { return nil }
            let body = String(line.dropFirst()) + "\n"
            switch first {
            case " ":
                seenOld += 1; seenNew += 1; old += body; new += body
                if changed { trailingContext += 1 } else { leadingContext += 1 }
            case "-":
                seenOld += 1; old += body; changed = true; trailingContext = 0
            case "+":
                seenNew += 1; new += body; changed = true; trailingContext = 0
            default: break
            }
        }
        guard inHunk, seenOld == expectedOld, seenNew == expectedNew,
              leadingContext < contextLimit, trailingContext < contextLimit else { return nil }
        return (status == "added" || status == "untracked" ? nil : old,
                status == "deleted" ? nil : new)
    }

    /// The counts in a `@@ -a,b +c,d @@` header; nil when it has no two ranges (a remote patch is untrusted).
    static func hunkCounts(_ header: String) -> (old: Int, new: Int)? {
        guard let start = header.index(header.startIndex, offsetBy: 3, limitedBy: header.endIndex),
              let end = header[start...].range(of: " @@") else { return nil }
        let ranges = header[start..<end.lowerBound]
            .split(separator: " ")
        guard ranges.count >= 2,
              let old = hunkCount(ranges[0], prefix: "-"),
              let new = hunkCount(ranges[1], prefix: "+") else { return nil }
        return (old, new)
    }

    private static func hunkCount(_ range: Substring, prefix: Character) -> Int? {
        guard range.first == prefix else { return nil }
        let value = range.dropFirst().split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
        guard let start = Int(value[0]), start >= 0 else { return nil }
        guard value.count == 2 else { return 1 }
        guard let count = Int(value[1]), count >= 0 else { return nil }
        return count
    }

    /// Writes the tab's turn patch (``DiffTurnPatch``) from the session host's
    /// `git.checkpoint.diff` of the tab's repository. Read-only: a pair never changes.
    private func writeTurnPatch(_ turn: DiffTurn?, in grant: DiffSessionGrant) async throws {
        guard let turn, let git else { throw PageError(code: "notAllowed", message: "This diff tab has no chat turn") }
        let diff: JSONValue
        do {
            diff = try await git.checkpointDiff(grant.repository, from: turn.from, to: turn.to)
        } catch {
            throw Self.pageError(error)
        }
        try await Self.write(diff, to: grant)
    }

    /// The patch can be megabytes: built and written off the main actor.
    @concurrent private static func write(_ diff: JSONValue, to grant: DiffSessionGrant) async throws {
        try grant.writeTurnPatch(DiffTurnPatch.make(diff))
    }

    /// Stops the open in flight and closes its session once it settles (it may
    /// have published its patch before the child stopped).
    private func stopOpening(grant: DiffSessionGrant) {
        guard let current = opening else { return }
        let id = current.session, task = current.task
        opening = nil
        task.cancel()
        discards.append(Task { [self] in
            _ = try? await task.value
            await closeQuietly(id, grant: grant)
        })
    }

    private func closeQuietly(_ id: String, grant: DiffSessionGrant) async {
        _ = try? await send("sessionClose", params: ["sessionId": .string(id), "capabilityToken": .string(grant.token)])
        sessions.remove(id)
    }

    private func send(_ method: String, params: [String: JSONValue]?) async throws -> JSONValue {
        guard let sidecar else { throw PageError(code: "sidecarUnavailable", message: "Diff sidecar is unavailable") }
        var envelope: [String: JSONValue] = ["id": .string(UUID().uuidString), "version": 1, "method": .string(method)]
        if let params { envelope["params"] = .object(params) }
        let body = Data(JSONValue.object(envelope).compactText.utf8)
        guard body.count <= Self.maximumRequestBytes else { throw PageError.invalidParams("request exceeds 1 MiB") }
        let reply: Data
        do {
            reply = try await sidecar.run(body)
        } catch let error as DiffSidecarError {
            throw Self.pageError(error)
        }
        guard let response = try? JSONValue.parse(reply) else {
            throw PageError(code: "invalidResponse", message: "Diff sidecar returned invalid JSON")
        }
        if let error = response["error"], error != .null {
            throw PageError(code: error["code"]?.stringValue ?? "sidecarFailed", message: error["message"]?.stringValue ?? "")
        }
        guard let result = response["result"], result["type"]?.stringValue != nil else {
            throw PageError(code: "missingResult", message: "Diff sidecar returned no result")
        }
        return result
    }

    static func openedSession(_ result: JSONValue) -> String? {
        guard result["type"]?.stringValue == "sessionOpened" else { return nil }
        return result["value"]?["sessionId"]?.stringValue
    }

    static func pageError(_ error: DiffSidecarError) -> PageError {
        switch error {
        case .busy: PageError(code: "busy", message: "Too many diff requests", retryable: true)
        case .timedOut: PageError(code: "timedOut", message: "The diff sidecar did not answer in time", retryable: true)
        case .cancelled: PageError(code: "cancelled", message: "cancelled")
        case .missingExecutable, .startFailed, .failed: PageError(code: "sidecarUnavailable", message: "Diff sidecar is unavailable")
        }
    }

    // MARK: Teardown

    /// The tab closed: stops the open in flight, closes every session this tab
    /// opened, then removes the grant (off the main actor).
    public func close() async {
        guard !isClosed else { return }
        isClosed = true
        events.removeAll()
        await retire()
    }

    /// Ends the current grant: the open in flight, its sessions, its files.
    private func retire() async {
        revertState.reset()
        guard let current = ready else { return }
        ready = nil
        guard let grant = try? await current.value.grant else { return }
        stopOpening(grant: grant)
        for discard in discards { await discard.value }
        discards.removeAll()
        for id in sessions.sorted() { await closeQuietly(id, grant: grant) }
        sessions.removeAll()
        remoteSessions.removeAll()
        await DiffPageRuntime.drop(grant)
    }
}

extension DiffOpenSource {
    /// The page's `DiffSource` (`{kind: "branch", baseRef?}` with `HEAD` for
    /// Uncommitted, `{kind: "staged" | "unstaged"}`); anything else is the default.
    init(page source: JSONValue?) {
        switch source?["kind"]?.stringValue {
        case "staged": self = .staged
        case "unstaged": self = .unstaged
        case "branch": self = .branch(base: source?["baseRef"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 })
        default: self = .default
        }
    }
}
