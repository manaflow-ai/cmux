import CmuxNextPages
import CmuxNextSettings
import Foundation

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
final class DiffPageProvider: PageProvider {
    static let methods: Set<String> = ["protocolHandshake", "sessionOpen", "sessionClose", "branchList", "branchChange"]
    static let configOp = "cmux.diff.config"
    static let languagesOp = "cmux.diff.languages"
    static let eventsStream = "cmux.diff.events"
    static let recentsOp = "cmux.diff.recents"
    static let chooseFolderOp = "cmux.diff.chooseFolder"
    static let openOp = "cmux.diff.open"
    static let notARepository = "cmux.diff.not_a_repo"
    /// The id the page closes before its first open has answered.
    static let pendingSessionID = "00000000-0000-0000-0000-000000000000"
    static let maximumRequestBytes = 1024 * 1024

    /// The tab's repository grant, nil while it shows the empty state.
    private(set) var ready: Task<DiffTabReady, any Error>?
    private let sidecar: (any DiffSidecarRunning)?
    private let languages: DiffLanguageFeed?
    private weak var host: (any DiffTabHosting)?
    /// Prefs and viewed marks (``DiffPageStores``); nil serves no store op.
    let stores: DiffPageStores?
    /// Sessions of the current grant this tab named or was given, not closed yet.
    private(set) var sessions: Set<String> = []
    private var opening: (session: String, task: Task<JSONValue, any Error>)?
    private var discards: [Task<Void, Never>] = []
    private var events: [UUID: (JSONValue) -> Void] = [:]
    private(set) var isClosed = false

    init(ready: Task<DiffTabReady, any Error>?, sidecar: (any DiffSidecarRunning)?, languages: DiffLanguageFeed?,
         host: (any DiffTabHosting)? = nil, stores: DiffPageStores? = nil) {
        self.ready = ready
        self.stores = stores
        self.sidecar = sidecar
        self.languages = languages
        self.host = host
    }

    /// The tab shows the empty state (no repository yet).
    var isPicking: Bool { ready == nil && !isClosed }

    func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        guard !isClosed else { throw PageError.closed }
        switch op {
        case Self.configOp:
            return try await config()
        case Self.languagesOp:
            guard let languages else { throw PageError.unknownOp(op) }
            return await languages.pack()
        case Self.recentsOp:
            guard let host else { throw PageError.unknownOp(op) }
            return await host.recents()
        case Self.chooseFolderOp:
            guard let host else { throw PageError.unknownOp(op) }
            let start = params["start"]?.stringValue.map { URL(fileURLWithPath: $0, isDirectory: true) }
            return await host.chooseFolder(start: start).map { ["path": .string($0.path)] } ?? .null
        case Self.openOp:
            guard let path = params["path"]?.stringValue, path.hasPrefix("/") else { throw PageError.invalidParams("path is required") }
            return try await open(folder: URL(fileURLWithPath: path, isDirectory: true), source: DiffOpenSource(page: params["source"]))
        default:
            if let value = try await storeCall(op, params: params) { return value }
            let method = String(op.dropFirst("cmux.diff.".count))
            guard op.hasPrefix("cmux.diff."), Self.methods.contains(method) else { throw PageError.unknownOp(op) }
            return try await request(method, params: params.objectValue ?? [:])
        }
    }

    func subscribe(_ stream: String, filter: JSONValue, context: PageCallContext,
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
        default:
            throw PageError.unknownOp(stream)
        }
    }

    /// Event subscribers (tests; the stdio sidecar has none to send).
    var eventSubscriberCount: Int { events.count }

    private func config() async throws -> JSONValue {
        guard let ready else { return withStores(["pick": true]) }
        do {
            return withStores(try await ready.value.config)
        } catch let failure as DiffTabFailure {
            return DiffPageConfig.failure(title: failure.title, message: failure.message)
        }
    }

    /// Shows the repository `folder` is in, from `source` (`cmux.diff.open`, a
    /// dropped folder): the config the page renders in place. The previous
    /// grant, its sessions and files are retired first.
    func open(folder: URL, source: DiffOpenSource) async throws -> JSONValue {
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
        let grant: DiffSessionGrant
        do {
            grant = try await ready.value.grant
        } catch let failure as DiffTabFailure {
            throw PageError(code: "sidecarUnavailable", message: failure.message)
        }
        var params = params
        params["capabilityToken"] = .string(grant.token)
        switch method {
        case "protocolHandshake":
            return try await send(method, params: nil)
        case "sessionOpen":
            return try await open(params, grant: grant)
        case "sessionClose":
            guard let id = params["sessionId"]?.stringValue else { throw PageError.invalidParams("sessionId is required") }
            if id == Self.pendingSessionID {
                stopOpening(grant: grant)
                return ["type": "sessionClosed"]
            }
            guard sessions.contains(id) else { throw PageError(code: "notAllowed", message: "Diff session is not authorized") }
            let result = try await send(method, params: params)
            sessions.remove(id)
            return result
        case "branchChange":
            params["groupId"] = .string(grant.group)
            let result = try await send(method, params: params)
            if let id = Self.openedSession(result) { sessions.insert(id) }
            return result
        default:
            return try await send(method, params: params)
        }
    }

    /// A new open replaces the one in flight (the page shows one session).
    private func open(_ params: [String: JSONValue], grant: DiffSessionGrant) async throws -> JSONValue {
        stopOpening(grant: grant)
        let id = UUID().uuidString.lowercased()
        var params = params
        params["sessionId"] = .string(id)
        sessions.insert(id)
        let task = Task { [self] in try await send("sessionOpen", params: params) }
        opening = (id, task)
        defer { if opening?.session == id { opening = nil } }
        return try await task.value
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
    func close() async {
        guard !isClosed else { return }
        isClosed = true
        events.removeAll()
        await retire()
    }

    /// Ends the current grant: the open in flight, its sessions, its files.
    private func retire() async {
        guard let current = ready else { return }
        ready = nil
        guard let grant = try? await current.value.grant else { return }
        stopOpening(grant: grant)
        for discard in discards { await discard.value }
        discards.removeAll()
        for id in sessions.sorted() { await closeQuietly(id, grant: grant) }
        sessions.removeAll()
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
