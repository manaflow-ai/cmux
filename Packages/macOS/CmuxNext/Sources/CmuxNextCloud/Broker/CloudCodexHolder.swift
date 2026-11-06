public import Foundation

/// The app's side of its Codex access holder for the person's own Cloud machines:
/// `cmux cloud codex-holder` (cmux-tui crate `cmux-cloud-codex-holder`, its protocol in that
/// crate's `serve.rs`). The holder's state machine, renewal, delivery record, machine probe and the
/// read of the Mac's own Codex sign-in all run there; the app starts it, answers its questions (the
/// Cloud credential, a machine's owner and status, the person's consent) and shows the device-code
/// prompt.
///
/// Creating it starts nothing. The first call starts the process; a call after it ended starts it
/// again. A quit closes its stdin, which leaves delivered access in place (``detachForQuit()``
/// does the same and waits for it).
@MainActor public final class CloudCodexHolder {
    public struct Configuration: Sendable {
        /// The bundled `cmux`; nil when the build has none (every call fails as unavailable).
        public let binary: URL?
        /// The app's Cloud folder; holders live in `root/codex-holders/<scope digest>`.
        public let root: URL
        public let userHome: URL
        /// The cmux API origin for the machines' exec and file routes.
        public let api: URL
        /// Where cmux keeps its machine client sessions (`cmux cloud machine-io`'s).
        public let cacheDirectory: URL?
        public let appVersion: String

        public init(binary: URL?, root: URL, userHome: URL, api: URL, cacheDirectory: URL?, appVersion: String) {
            self.binary = binary; self.root = root; self.userHome = userHome
            self.api = api; self.cacheDirectory = cacheDirectory; self.appVersion = appVersion
        }
    }

    /// What the app answers.
    public struct Answers {
        /// The person's Cloud access token (refreshed as needed); nil when signed out.
        public var credential: @Sendable () async -> String?
        /// The holder child's executable (acpmux), resolved off the main thread.
        public var acpmux: @Sendable () async -> URL?
        /// The signed-in account scope now.
        public var currentScope: @MainActor () -> CloudCodexBrokerScope?
        /// Whether the person owns `machineID` (its app link's owner answer).
        public var ownsMachine: @MainActor (String) async -> Bool
        /// Whether `machineID` runs now, from the app's record (never a wake).
        public var isLive: @MainActor (String) -> Bool

        public init(credential: @escaping @Sendable () async -> String?, acpmux: @escaping @Sendable () async -> URL?,
                    currentScope: @escaping @MainActor () -> CloudCodexBrokerScope?,
                    ownsMachine: @escaping @MainActor (String) async -> Bool, isLive: @escaping @MainActor (String) -> Bool) {
            self.credential = credential; self.acpmux = acpmux; self.currentScope = currentScope
            self.ownsMachine = ownsMachine; self.isLive = isLive
        }
    }

    /// The person's yes to using the Mac's own Codex sign-in (`cloud.useMyCodexLoginOnMyCloudMachines`);
    /// nil or false: the holder never reads it.
    public var consent: (@MainActor () -> Bool)?

    private struct Run {
        let askLocalSignIn: (@MainActor @Sendable () async -> Bool)?
        let presentDeviceCode: @MainActor @Sendable (CloudCodexLoginPrompt) async -> Bool
    }

    private struct Reply: Sendable {
        var ok: Bool
        var flag: Bool?
        var code: String
        var message: String
    }

    private let answers: Answers
    private let pipe: CloudCodexHolderPipe?
    private let outgoing: AsyncStream<CloudCodexHolderPipe.Line>.Continuation
    private var nextID = 0
    private var replies: [Int: CheckedContinuation<Reply, Never>] = [:]
    private var runs: [Int: Run] = [:]
    private var asks: [Int: Task<Void, Never>] = [:]

    public init(configuration: Configuration, answers: Answers) {
        self.answers = answers
        // Bounded: a line past the cap fails its request (``send(_:id:)``); the holder's own lines past
        // it end that child (``CloudCodexHolderPipe``), which fails what it had not answered.
        let (lines, outgoing) = AsyncStream<CloudCodexHolderPipe.Line>.makeStream(bufferingPolicy: .bufferingOldest(Self.backlog))
        let (events, sink) = AsyncStream<CloudCodexHolderPipe.Event>.makeStream(bufferingPolicy: .bufferingOldest(Self.backlog))
        self.outgoing = outgoing
        var config: [String: Any] = [
            "op": "config", "root": configuration.root.path, "user_home": configuration.userHome.path,
            "api": configuration.api.absoluteString, "app_version": configuration.appVersion,
        ]
        if let cache = configuration.cacheDirectory { config["cache_dir"] = cache.path }
        let configLine = (try? JSONSerialization.data(withJSONObject: config)) ?? Data()
        let pipe = configuration.binary.map { CloudCodexHolderPipe(binary: $0, config: configLine, events: sink) }
        self.pipe = pipe
        let acpmux = answers.acpmux
        // Stop conditions: the send loop ends when `outgoing` finishes (deinit), the event loop when
        // the pipe's events finish (the pipe goes away with it).
        // task-owner: both loops end with their streams (above).
        Task { [weak self] in
            for await line in lines {
                guard let pipe else { self?.failed(line.id); continue }
                let path: URL? = await pipe.isRunning ? nil : await acpmux()
                if !(await pipe.send(line, acpmux: path)) { self?.failed(line.id) }
            }
        }
        // task-owner: ends when the pipe's events finish (the pipe goes away with the send loop).
        Task { [weak self] in
            for await event in events { self?.take(event) }
        }
    }

    deinit {
        outgoing.finish()
    }

    // MARK: The app's calls

    /// Finishes one confirmed transfer, showing a native device-code prompt only when the holder
    /// needs its first login. `askLocalSignIn` comes first then: the one-time consent to use the Mac's
    /// own Codex sign-in (true when given and the Mac has one), so no device code shows. A cancel of
    /// the caller's task ends the run (its prompt closes) and throws `CancellationError`.
    public func run(machineID: String, scope: CloudCodexBrokerScope, confirmed: Bool, forceRefresh: Bool = false,
                    askLocalSignIn: (@MainActor @Sendable () async -> Bool)? = nil,
                    presentDeviceCode: @escaping @MainActor @Sendable (CloudCodexLoginPrompt) async -> Bool) async throws {
        try Task.checkCancellation()
        let id = takeID()
        runs[id] = Run(askLocalSignIn: askLocalSignIn, presentDeviceCode: presentDeviceCode)
        defer { runs[id] = nil }
        let outgoing = outgoing
        let reply = await withTaskCancellationHandler {
            await request(id, "run", ["machine": machineID, "scope": Self.json(scope), "confirmed": confirmed,
                                      "force": forceRefresh, "ask_local": askLocalSignIn != nil])
        } onCancel: {
            if let data = try? JSONSerialization.data(withJSONObject: ["op": "cancel", "run": id]) {
                outgoing.yield(.init(data: data))
            }
        }
        try Self.check(reply)
    }

    /// Whether the holder already serves `machineID` in `scope` (a repeat would only risk its access).
    public func delivers(machineID: String, scope: CloudCodexBrokerScope) async -> Bool {
        await request(takeID(), "delivers", ["machine": machineID, "scope": Self.json(scope)]).flag ?? false
    }

    /// Each machine list the app reads: the holder takes back the signed-in scope's live machines
    /// from its delivery record (retrying a machine whose link still connects after 15, 30 and 60 s).
    public func machinesListed(_ machines: [CloudMachine]) {
        send(["op": "listed", "live": machines.filter { $0.status.isLive }.map(\.id)])
    }

    /// The signed-in account or team changed: holders of other scopes erase and end.
    public func scopeDidChange() async { _ = await request(takeID(), "scope_changed", [:]) }

    /// The Cloud off switch: an immediate fence for new requests and writes; holders tear down.
    public func setAvailable(_ enabled: Bool) {
        guard let data = line(["op": "available", "enabled": enabled]) else { return }
        outgoing.yield(.init(data: data, available: enabled))
    }

    public func revoke(machineID: String, scope: CloudCodexBrokerScope) async throws {
        try Self.check(await request(takeID(), "revoke", ["machine": machineID, "scope": Self.json(scope)]))
    }

    /// A destroyed machine: its delivery record and pending cleanup are dropped.
    public func machineWasDeleted(_ machineID: String, scope: CloudCodexBrokerScope) async {
        _ = await request(takeID(), "deleted", ["machine": machineID, "scope": Self.json(scope)])
    }

    /// A quit: renewal stops and delivered access stays on each machine (#33482).
    public func detachForQuit() async {
        guard pipe != nil else { return }
        _ = await request(takeID(), "detach", [:])
    }

    /// Sign-out: every machine's access is erased and every holder ends.
    public func signOut() async { _ = await request(takeID(), "sign_out", [:]) }

    /// Whether the Mac's own Codex sign-in holds access to give now.
    public func hasMacCodexAccess() async -> Bool {
        await request(takeID(), "local_access", [:]).flag ?? false
    }

    // MARK: The pipe

    /// The most lines waiting either way.
    static let backlog = 4096

    private func takeID() -> Int {
        nextID += 1
        return nextID
    }

    private func line(_ fields: [String: Any]) -> Data? {
        var fields = fields
        fields["current"] = answers.currentScope().map { Self.json($0) as Any } ?? NSNull()
        return try? JSONSerialization.data(withJSONObject: fields)
    }

    private func send(_ fields: [String: Any], id: Int? = nil) {
        guard let data = line(fields), case .enqueued = outgoing.yield(.init(data: data, id: id)) else { return failed(id) }
    }

    private func request(_ id: Int, _ op: String, _ fields: [String: Any]) async -> Reply {
        var fields = fields
        fields["op"] = op
        fields["id"] = id
        return await withCheckedContinuation { continuation in
            replies[id] = continuation
            send(fields, id: id)
        }
    }

    private func failed(_ id: Int?) {
        guard let id, let continuation = replies.removeValue(forKey: id) else { return }
        continuation.resume(returning: Reply(ok: false, code: Self.unavailable.code, message: Self.unavailable.message))
    }

    private func take(_ event: CloudCodexHolderPipe.Event) {
        switch event {
        case .ended(_, let ids):
            for id in ids { failed(id) }
            for ask in asks.values { ask.cancel() }
            asks = [:]
        case .line(let generation, let data):
            guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
            if let id = object["reply"] as? Int {
                guard let continuation = replies.removeValue(forKey: id) else { return }
                continuation.resume(returning: Reply(ok: object["ok"] as? Bool ?? false, flag: object["value"] as? Bool,
                                                     code: object["error"] as? String ?? "failed",
                                                     message: object["message"] as? String ?? Self.unavailable.message))
            } else if let id = object["cancel_ask"] as? Int {
                asks.removeValue(forKey: id)?.cancel()
            } else if let kind = object["ask"] as? String, let id = object["id"] as? Int {
                let fields = Self.fields(object)
                asks[id] = Task { [weak self] in
                    let value = await self?.answer(kind, fields: fields) ?? .null
                    self?.finishAsk(id, generation: generation, value: value)
                }
            }
        }
    }

    private enum Answer: Sendable {
        case flag(Bool)
        case text(String)
        case null
    }

    private func finishAsk(_ id: Int, generation: Int, value: Answer) {
        let json: Any = switch value {
        case .flag(let flag): flag
        case .text(let text): text
        case .null: NSNull()
        }
        guard asks.removeValue(forKey: id) != nil, !Task.isCancelled,
              let data = try? JSONSerialization.data(withJSONObject: ["op": "answer", "id": id, "value": json]) else { return }
        outgoing.yield(.init(data: data, answerFor: generation))
    }

    /// An ask's string and number fields (the only kinds the holder sends).
    private static func fields(_ object: [String: Any]) -> [String: String] {
        object.reduce(into: [:]) { fields, item in
            if let text = item.value as? String { fields[item.key] = text }
            else if let number = item.value as? Int { fields[item.key] = String(number) }
        }
    }

    private func answer(_ kind: String, fields: [String: String]) async -> Answer {
        let machine = fields["machine"] ?? ""
        let run = fields["run"].flatMap { Int($0) }.flatMap { runs[$0] }
        switch kind {
        case "credential": return await answers.credential().map(Answer.text) ?? .null
        case "owner": return .flag(await answers.ownsMachine(machine))
        case "live": return .flag(answers.isLive(machine))
        case "consent": return .flag(consent?() ?? false)
        case "local_sign_in": return .flag(await run?.askLocalSignIn?() ?? false)
        case "device_code":
            guard let run, let url = fields["url"].flatMap({ URL(string: $0) }), let code = fields["code"] else { return .flag(false) }
            return .flag(await run.presentDeviceCode(CloudCodexLoginPrompt(verificationURL: url, userCode: code)))
        default: return .null
        }
    }

    private static func json(_ scope: CloudCodexBrokerScope) -> [String: Any] {
        ["user": scope.userID, "team": scope.teamID.map { $0 as Any } ?? NSNull()]
    }

    private static let unavailable = CloudCodexHolderError(code: "broker_unavailable",
                                                           message: "The local Codex sign-in holder is unavailable.")

    private static func check(_ reply: Reply) throws {
        guard !reply.ok else { return }
        if reply.code == "interrupted" { throw CancellationError() }
        throw CloudCodexHolderError(code: reply.code, message: reply.message)
    }
}

/// A holder call that failed: the holder's error code (`consent_required`, `target_offline`, ...)
/// and its text for the person.
public struct CloudCodexHolderError: Error, LocalizedError, Sendable, Equatable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }

    public var errorDescription: String? { message }
}
