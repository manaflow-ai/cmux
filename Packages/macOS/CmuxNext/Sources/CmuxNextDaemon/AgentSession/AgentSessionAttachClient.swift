public import Foundation
import os

/// One agent chat tab of a session daemon, attached over a dedicated daemon connection
/// (`agent-session-attach-v1`, cmux-tui/spec/commands.md "Agent session attach"): how the app
/// shows a chat whose acpmux runs on the daemon's machine. A separate socket from the control
/// connection, so a long transcript replay never delays the tree.
///
/// Connects on the first attach. A dropped connection ends the attachment (`closed`), and the
/// page reconnects with a fresh client and replays from the newest seq it holds. Nothing here
/// names a session, a folder or a command: the daemon pins the session from its tab record.
public actor AgentSessionAttachClient {
    public typealias EndpointProvider = @Sendable () async throws -> DaemonEndpoint
    /// One push for the attachment: `agent-session-record`, `-permission`, `-changed`, `-presence` or `-closed`, with
    /// the line's JSON object.
    public typealias EventHandler = @Sendable (_ event: String, _ line: Data) -> Void

    /// How the daemon attachment is used. Observation has its own capability and command so a
    /// missing observer feature can never silently fall back to a writable attach.
    public enum Mode: Sendable, Equatable {
        case attach
        case observe

        var capability: String {
            switch self {
            case .attach: return DaemonCapability.agentSessionAttach.rawValue
            case .observe: return DaemonCapability.agentSessionObserve.rawValue
            }
        }

        var command: String {
            switch self {
            case .attach: return "agent-session-attach"
            case .observe: return "agent-session-observe"
            }
        }

        var clientInfoKind: String { command }
        var clientInfoName: String {
            switch self {
            case .attach: return "cmux-next agent attach"
            case .observe: return "cmux-next agent observer"
            }
        }

        var unsupportedMessage: String {
            let feature = self == .observe ? "agent session observation" : "agent session attach"
            return "the daemon does not serve \(feature)"
        }
    }

    public static let capability = DaemonCapability.agentSessionAttach.rawValue
    /// A Cloud machine's running link id while its attach answer says the caller owns it, else nil
    /// (`CloudMachineLink.ownerLink`).
    public typealias OwnerLink = @Sendable () async -> Int?
    /// Whether a Cloud machine's link says it is a teammate's (`CloudMachineLinks.teammate`).
    public typealias Teammate = @Sendable () async -> Bool
    /// Asked once when a connection fails (its endpoint, its socket or its handshake): true once
    /// the machine's link came back, and the connection is tried once more.
    public typealias Reconnect = @Sendable () async -> Bool

    private let surface: UInt64
    private let mode: Mode
    private let endpoint: EndpointProvider
    private let reconnect: Reconnect?
    private let requestTimeout: Duration
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "agent-attach")
    private var transport: LineTransport?
    private var connecting: Task<(LineTransport, Served), any Error>?
    private let handler = HandlerBox()
    /// The newest ``attach(afterSeq:beforeSeq:limit:kinds:events:)``, which the next one waits for.
    private var attachTail: Task<Void, Never>?
    private var closed = false
    /// A quiet try (``sharedConnection(quiet:)``) lost its connection in its handshake and told no
    /// one yet.
    private var quietLoss = false
    /// What ``transport``'s daemon serves, read from its own `identify` on that connection and
    /// replaced only together with it.
    private var served = Served()
    /// Counts the connections this client began to make (``connect(quiet:)``).
    private var connectsBegun = 0
    /// The newest connection made: its number in ``connectsBegun`` and whether its close tells
    /// the attachment (cleared to retire it silently).
    private var newest: (transport: ObjectIdentifier, number: Int, tells: OSAllocatedUnfairLock<Bool>)?

    private struct Served: Sendable {
        /// `agent-session-start-v1`.
        var start = false
        /// `agent-session-start-no-cwd-v1`.
        var startNoCwd = false
        /// `agent-session-trust-v1`.
        var trust = false
        /// `agent-session-start-keyed-reason-v1`.
        var keyedReason = false
        /// `agent-session-start-vm-kind-v1`.
        var vmKind = false
        /// `agent-session-start-model-v1`.
        var model = false
        /// `agent-session-trust-vm-kind-v1`.
        var trustVMKind = false
        /// `agent-session-children-v1`.
        var children = false
        /// `agent-session-presence-v1`.
        var presence = false
        /// `agent-session-folders-v1`.
        var folders = false
        /// `agent-session-settings-v1`.
        var settings = false
    }

    /// A start that needs the app's person key in that machine's acpmux (cx-0w0jj): `instance`
    /// is the acpmux run the app holds a key for, nil when it holds none.
    public struct PersonKey: Sendable, Equatable {
        public var instance: String?
        public init(instance: String?) { self.instance = instance }
    }

    /// `surface`: the tab's surface id in the daemon's store.
    /// `reconnect`: asked when a connection fails (``Reconnect``); nil, never tried again.
    public init(surface: UInt64, requestTimeout: Duration = .seconds(10), mode: Mode = .attach,
                reconnect: Reconnect? = nil, endpoint: @escaping EndpointProvider) {
        self.surface = surface
        self.mode = mode
        self.endpoint = endpoint
        self.reconnect = reconnect
        self.requestTimeout = requestTimeout
    }

    /// Subscribes and returns the attach page's JSON. Pushes go to `events` from then on.
    public func attach(afterSeq: UInt64?, beforeSeq: UInt64?, limit: Int?, kinds: [String]?,
                       events: @escaping EventHandler) async throws -> Data {
        handler.set(events)
        // One attach at a time: the daemon refuses a second attach of the tab while the first still
        // connects (its slot is reserved: `agent_session.limit`, "too many attached agent tabs"), and
        // the remote wire asks two at once (the page's session list and its attach, sent together
        // since #27755). The later one waits and is then a page of the live attachment.
        let previous = attachTail
        let command = mode.command, params = page(afterSeq, beforeSeq, limit, kinds)
        // task-owner: this attach; the next attach waits on it, and the caller's cancel cancels it
        let task = Task {
            await previous?.value
            return try await self.call(command, params)
        }
        attachTail = Task { _ = await task.result }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    public func events(afterSeq: UInt64?, beforeSeq: UInt64?, limit: Int?, kinds: [String]?) async throws -> Data {
        try await call("agent-session-events", page(afterSeq, beforeSeq, limit, kinds))
    }

    /// `agent-session-start` (`agent-session-start-v1`): the daemon starts a new chat for the tab
    /// in its own machine's acpmux (policy `ask`) and binds it; returns the new session id. A
    /// daemon that does not serve the verb is refused here (`agent_session.start_unsupported`),
    /// so no start ever falls back to another machine.
    ///
    /// With `personKey` the daemon starts only when its acpmux holds that key, else it refuses with
    /// `agent_session.needs_keyed_start` and its facts in ``AgentSessionAttachError/details``. A
    /// daemon without `agent-session-start-keyed-reason-v1` gets no such param (it would refuse it).
    ///
    /// An explicit `model` requires `agent-session-start-model-v1`; older daemons retain the
    /// existing cwd/harness start when no model was requested.
    ///
    /// `ownerLink`: set for a Cloud machine (from the app's own record of it, never the guest's).
    /// A chat starts there only while it gives the same link id before the connection and as the
    /// start is sent (the link's attach answer said the signed-in caller owns the machine, and
    /// that link still runs), through any daemon; a link that came up while the start connected is
    /// asked again on the live connection (``ownedConnection(_:check:)``), and anything else is
    /// refused here (`agent_session.host_unverified`). The daemon then gets `vm_kind: "owner"` when this
    /// connection's own `identify` lists `agent-session-start-vm-kind-v1`. The start goes over
    /// that same connection, checked before it: if it ended meanwhile the start fails, never
    /// goes out over a new one.
    public func start(cwd: String?, harness: String?, homeConfirmed: Bool = false, personKey: PersonKey? = nil,
                      ownerLink: OwnerLink? = nil, model: String? = nil) async throws -> String {
        guard mode == .attach else {
            throw AgentSessionAttachError(code: Self.startUnsupported, message: "a read-only agent session cannot start a chat")
        }
        let (transport, served, callerOwnsVM) = try await ownedConnection(ownerLink) { served in
            guard served.start else {
                throw AgentSessionAttachError(code: Self.startUnsupported, message: "the daemon does not serve agent session start")
            }
            guard model == nil || served.model else {
                throw AgentSessionAttachError(code: Self.startUnsupported, message: "the daemon does not support choosing a start model")
            }
        }
        let params = Self.startParams(cwd: cwd, harness: harness, homeConfirmed: homeConfirmed, personKey: personKey,
                                      servesKeyedReason: served.keyedReason, callerOwnsVM: callerOwnsVM, servesVMKind: served.vmKind,
                                      model: model, servesModel: served.model)
        guard !transport.isClosed else {
            throw AgentSessionAttachError(code: "agent_session.closed", message: "the connection ended before the start was sent")
        }
        let data = try await call("agent-session-start", params, on: transport)
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let session = object["session"] as? String, !session.isEmpty else {
            throw AgentSessionAttachError(code: "agent_session.refused", message: "agent-session-start answered no session")
        }
        return session
    }

    /// The params of ``start(cwd:harness:homeConfirmed:personKey:ownerLink:)``: a param a daemon
    /// does not advertise is never sent (its `deny_unknown_fields` would refuse the start).
    static func startParams(cwd: String?, harness: String?, homeConfirmed: Bool, personKey: PersonKey?,
                            servesKeyedReason: Bool, callerOwnsVM: Bool, servesVMKind: Bool,
                            model: String? = nil, servesModel: Bool = false) -> [String: any Sendable] {
        var params: [String: any Sendable] = [:]
        if let cwd { params["cwd"] = cwd }
        if let harness { params["harness"] = harness }
        if servesModel, let model, !model.isEmpty { params["model"] = model }
        if homeConfirmed { params["home_confirmed"] = true }
        if let personKey, servesKeyedReason {
            params["require_person_key"] = true
            if let instance = personKey.instance { params["person_instance"] = instance }
        }
        if callerOwnsVM, servesVMKind { params["vm_kind"] = "owner" }
        return params
    }

    /// `agent-session-trust` (`agent-session-trust-v1`): the trust of `cwd` on the daemon's machine
    /// (acpmux's `acp.trust.get` reply), or with `level` the person's answer recorded there
    /// (`acp.trust.set`). Only the person's own answer is ever sent (the pane's relay).
    ///
    /// `ownerLink`: as for ``start(cwd:harness:homeConfirmed:personKey:ownerLink:)``, the same rule:
    /// a Cloud machine's trust is asked or set only on the owner answer of the link the call goes
    /// over, through any daemon, with `vm_kind: "owner"` to one with `agent-session-trust-vm-kind-v1`.
    public func trust(cwd: String, level: String?, homeConfirmed: Bool = false, ownerLink: OwnerLink? = nil) async throws -> Data {
        guard mode == .attach else {
            throw AgentSessionAttachError(code: Self.startUnsupported, message: "a read-only agent session cannot change trust")
        }
        let (transport, served, callerOwnsVM) = try await ownedConnection(ownerLink) { served in
            guard served.trust else {
                throw AgentSessionAttachError(code: Self.startUnsupported, message: "the daemon does not serve agent session trust")
            }
        }
        var params: [String: any Sendable] = ["cwd": cwd]
        if let level { params["level"] = level }
        if homeConfirmed { params["home_confirmed"] = true }
        if callerOwnsVM, served.trustVMKind { params["vm_kind"] = "owner" }
        // The call goes over the connection its owner answer and capabilities were checked for.
        guard !transport.isClosed else {
            throw AgentSessionAttachError(code: "agent_session.closed", message: "the connection ended before the trust call was sent")
        }
        return try await call("agent-session-trust", params, on: transport)
    }

    /// How many times ``ownedConnection(_:check:)`` reads the owner answer around a connection.
    static let ownerAnswerReads = 3

    /// The live connection, what its daemon serves (`check` refuses what it lacks) and, for a
    /// Cloud machine, the owner answer of the link it goes over: the same id read before the
    /// connection began to be made and once it is live (``ownerAnswer(_:before:)``), so an owner
    /// answer never carries over to another link. When the reads differ, or the connection was
    /// made before the first read, the link came up or came back while the call connected (a new
    /// Cloud machine's first start, a down machine that reconnects on use): that connection is
    /// retired, telling no attachment, and both reads are taken again around a new one over the
    /// live link, at most ``ownerAnswerReads`` times, with no wait between. A client with an
    /// attachment keeps its connection and is refused instead. A link that never gives one owner
    /// answer twice in a row (no link, a team machine, a link that keeps restarting) is refused.
    private func ownedConnection(_ ownerLink: OwnerLink?, check: (Served) throws -> Void) async throws
        -> (LineTransport, Served, callerOwnsVM: Bool) {
        guard let ownerLink else {
            let (transport, served) = try await liveConnection()
            try check(served)
            return (transport, served, false)
        }
        for read in 1...Self.ownerAnswerReads {
            let before = await ownerLink()
            let begun = connectsBegun
            let (transport, served) = try await liveConnection()
            try check(served)
            let madeInside = newest.map { $0.transport == ObjectIdentifier(transport) && $0.number > begun } ?? false
            if madeInside, let owns = try? await Self.ownerAnswer(ownerLink, before: before) { return (transport, served, owns) }
            guard read < Self.ownerAnswerReads, handler.current == nil else { break }
            retire(transport)
        }
        throw Self.notOwner
    }

    /// Ends `transport` without telling the attachment it ended (``ownedConnection(_:check:)``).
    private func retire(_ transport: LineTransport) {
        if let newest, newest.transport == ObjectIdentifier(transport) { newest.tells.withLock { $0 = false } }
        if self.transport === transport { self.transport = nil }
        transport.close()
    }

    private static var notOwner: AgentSessionAttachError {
        AgentSessionAttachError(code: "agent_session.host_unverified", message: "the Cloud API did not say this machine is yours")
    }

    /// For a Cloud machine (`ownerLink` set): true when the link gives the same id now as `before`
    /// (read before the connection), so the owner answer is the one of the link the call goes over;
    /// refused otherwise. False for a machine that is not a Cloud one.
    private static func ownerAnswer(_ ownerLink: OwnerLink?, before: Int?) async throws -> Bool {
        guard let ownerLink else { return false }
        guard let before, await ownerLink() == before else { throw notOwner }
        return true
    }

    /// The code ``start(cwd:harness:)`` throws for a daemon without `agent-session-start-v1`.
    public static let startUnsupported = "agent_session.start_unsupported"

    public func prompt(id: String, text: String) async throws -> Data {
        try await call("agent-session-prompt", ["prompt_id": id, "text": text])
    }

    public func cancel() async throws {
        _ = try await call("agent-session-cancel", [:])
    }

    /// `agent-session-permission`, with a question's `answers` and `annotations` (JSON objects)
    /// and the person's decision proof of a relayed allow when there is one (cx-0q7o): the daemon
    /// passes them to acpmux unchanged, and acpmux decides (an answer's proof covers both).
    public func permission(id: String, option: String, answers: Data? = nil, annotations: Data? = nil,
                           decisionNonce: String? = nil, personDecision: String? = nil) async throws {
        var params: [String: any Sendable] = ["permission_id": id, "option_id": option]
        if let decisionNonce, let personDecision {
            params["decision_nonce"] = decisionNonce
            params["person_decision"] = personDecision
        }
        _ = try await call("agent-session-permission", params, json: ["answers": answers, "annotations": annotations])
    }

    public func detach() async {
        _ = try? await call("agent-session-detach", [:])
    }

    /// `agent-session-children` (`agent-session-children-v1`): the chats the attached tab's session
    /// started on the daemon's machine (`{sessions}`, acpmux summaries); the attachment then
    /// streams their changes too. A daemon without the verb lists none.
    /// That machine's folders for a new chat (`agent-session-folders-v1`): its work folder
    /// (`default`, nil when it has none) and the folders under it. A daemon without the verb
    /// answers none (the app then asks the person for a folder).
    public func folders() async throws -> (work: String?, folders: [String]) {
        guard mode == .attach else { return (nil, []) }
        _ = try await liveTransport()
        guard served.folders else { return (nil, []) }
        let data = try await call("agent-session-folders", [:])
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let absolute = { (path: String) in path.hasPrefix("/") }
        let work = (object["default"] as? String).flatMap { absolute($0) ? $0 : nil }
        return (work, (object["folders"] as? [String] ?? []).filter(absolute))
    }

    /// Whether this daemon accepts an omitted cwd on `agent-session-start`.
    /// Older daemons require a folder and must keep the work-folder fallback.
    public func supportsNoCwd() async throws -> Bool {
        guard mode == .attach else { return false }
        _ = try await liveTransport()
        return served.startNoCwd
    }

    public func children() async throws -> Data {
        _ = try await liveTransport()
        guard served.children else { return Data(#"{"sessions":[]}"#.utf8) }
        return try await call("agent-session-children", [:])
    }

    /// `agent-session-typing` (`agent-session-presence-v1`): the person starts or stops typing in
    /// the attached chat. A daemon without the verb hears nothing (no one else is shown there).
    public func typing(_ on: Bool) async throws {
        _ = try await liveTransport()
        guard served.presence else { return }
        _ = try await call("agent-session-typing", ["on": on])
    }

    /// `agent-session-view` (`agent-session-presence-v1`): whether the person's window shows the
    /// attached chat now. A daemon without the verb keeps counting the attach as shown.
    public func view(_ visible: Bool) async throws {
        _ = try await liveTransport()
        guard served.presence else { return }
        _ = try await call("agent-session-view", ["visible": visible])
    }

    /// The code the setting verbs throw for a daemon without `agent-session-settings-v1`.
    public static let settingsUnsupported = "agent_session.settings_unsupported"

    /// `agent-session-set-model` (`agent-session-settings-v1`): the attached chat's model, as
    /// acpmux's `session/set_model` on the tab's own session; acpmux's answer.
    public func setModel(_ modelId: String) async throws -> Data {
        try await setting("agent-session-set-model", ["model_id": modelId])
    }

    /// `agent-session-set-mode` (`agent-session-settings-v1`): acpmux's `session/set_mode`.
    public func setMode(_ modeId: String) async throws -> Data {
        try await setting("agent-session-set-mode", ["mode_id": modeId])
    }

    /// `agent-session-set-config` (`agent-session-settings-v1`): acpmux's
    /// `session/set_config_option`, which answers the agent's whole `configOptions`.
    public func setConfig(id configId: String, value: String) async throws -> Data {
        try await setting("agent-session-set-config", ["config_id": configId, "value": value])
    }

    private func setting(_ cmd: String, _ params: [String: any Sendable]) async throws -> Data {
        _ = try await liveTransport()
        guard served.settings else {
            throw AgentSessionAttachError(code: Self.settingsUnsupported,
                                          message: "update cmux on that machine to change this chat's model, mode or options from here")
        }
        return try await call(cmd, params)
    }

    /// Reads one image from the attached session's host acpmux (`agent-session-media`).
    public func media(path: String) async throws -> Data {
        _ = try await liveTransport()
        return try await call("agent-session-media", ["path": path])
    }

    /// Sends one Cloud repository action over this chat's authenticated daemon attachment.
    /// Repository actions are cmux-tui frame commands, so they share this connection rather
    /// than going through acpmux's JSON-RPC socket.
    public func cloudRepository(method: String, params: [String: any Sendable], timeout: Duration? = nil) async throws -> Data {
        guard Self.cloudRepositoryMethods.contains(method) else {
            throw AgentSessionAttachError(code: "cloud_repo.unsupported", message: "unsupported Cloud repository action")
        }
        return try await call(method, params, timeout: timeout)
    }

    private static let cloudRepositoryMethods: Set<String> = [
        "cloud.repo.sync", "cloud.repo.list", "cloud.repo.add", "cloud.repo.attached", "cloud.repo.wait_github",
    ]

    /// Ends the attachment and the connection; no push after it.
    public func close() {
        closed = true
        handler.set(nil)
        connecting?.cancel()
        connecting = nil
        transport?.close()
        transport = nil
    }

    // MARK: Private

    private func page(_ after: UInt64?, _ before: UInt64?, _ limit: Int?, _ kinds: [String]?) -> [String: any Sendable] {
        var params: [String: any Sendable] = [:]
        if let after { params["after_seq"] = after }
        if let before { params["before_seq"] = before }
        if let limit { params["limit"] = limit }
        if let kinds { params["kinds"] = kinds }
        return params
    }

    /// One verb on the tab; the result's `data` as JSON, or the daemon's refusal. Each of `json`
    /// (a question's answers and annotations, as JSON) goes in the request as it is.
    /// `on`: that connection only (no reconnect), else the live one.
    private func call(_ cmd: String, _ params: [String: any Sendable], json: [String: Data?] = [:],
                      timeout: Duration? = nil, on pinned: LineTransport? = nil) async throws -> Data {
        let transport: LineTransport
        if let pinned { transport = pinned } else { transport = try await liveTransport() }
        var object: [String: Any] = params
        for case let (key, data?) in json {
            object[key] = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        }
        object["cmd"] = cmd
        object["surface"] = surface
        // Integers stay integers (the daemon reads u64 seqs and surface ids).
        let fields = try JSONSerialization.data(withJSONObject: object)
        let response: LineTransport.Response
        do {
            response = try await transport.request(cmd: cmd, timeout: timeout ?? requestTimeout) { id in
                Data(#"{"id":\#(id),"#.utf8) + fields.dropFirst()
            }
        } catch DaemonError.command(_, let message, let code, let details, _) {
            throw AgentSessionAttachError(code: code ?? "agent_session.refused", message: message, details: details)
        }
        return Self.data(of: response.line)
    }

    private func liveTransport() async throws -> LineTransport {
        try await liveConnection().0
    }

    /// The live connection and what its daemon serves. With ``reconnect``, a connection that fails
    /// (its endpoint, its socket or its handshake) asks it and is tried once more. The wait runs in
    /// the caller's task, so a cancelled call stops waiting, and nothing is sent after it. A failed
    /// first try ends no attachment: its loss is told only when no retry follows or it fails too.
    private func liveConnection() async throws -> (LineTransport, Served) {
        guard let reconnect else { return try await sharedConnection(quiet: false) }
        do {
            let connection = try await Self.retrying({ last in try await self.sharedConnection(quiet: !last) }, reconnect: reconnect)
            quietLoss = false
            return connection
        } catch {
            // The quiet first try's lost connection, unless the retry's own close told it.
            if quietLoss, let current = handler.take() {
                current("agent-session-closed", Data(#"{"event":"agent-session-closed","reason":"connection_lost"}"#.utf8))
            }
            quietLoss = false
            throw error
        }
    }

    /// `body(false)`, which asks `reconnect` when it throws, and runs `body(true)` (the last try)
    /// when that answers true. A cancelled call reconnects nothing and is not retried; a failure
    /// that is not the link's, or a link that does not come back, throws as it did.
    public static func retrying<T: Sendable>(_ body: @Sendable (_ last: Bool) async throws -> T, reconnect: Reconnect) async throws -> T {
        do {
            return try await body(false)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard !Task.isCancelled, await reconnect() else { throw error }
            try Task.checkCancellation()
            return try await body(true)
        }
    }

    /// The connection one try opens, shared with a try already running. `quiet`: its close before
    /// its handshake finished ends no attachment (``quietLoss`` remembers it).
    private func sharedConnection(quiet: Bool) async throws -> (LineTransport, Served) {
        if closed { throw AgentSessionAttachError(code: "agent_session.closed", message: "closed") }
        if let transport, !transport.isClosed { return (transport, served) }
        transport = nil
        if let connecting { return try await connecting.value }
        let task = Task { try await self.connect(quiet: quiet) }
        connecting = task
        defer { connecting = nil }
        let (transport, served) = try await task.value
        if closed {
            transport.close()
            throw AgentSessionAttachError(code: "agent_session.closed", message: "closed")
        }
        self.transport = transport
        self.served = served
        return (transport, served)
    }

    private func connect(quiet: Bool) async throws -> (LineTransport, Served) {
        connectsBegun += 1
        let number = connectsBegun
        let transport: LineTransport
        do {
            let endpoint = try await self.endpoint()
            transport = try LineTransport(path: endpoint.socketPath)
        } catch {
            if quiet { quietLoss = true }
            throw error
        }
        let handler = handler
        let surface = surface
        // A quiet try's close tells the attachment only once its handshake finished.
        let tells = OSAllocatedUnfairLock(initialState: !quiet)
        transport.start(
            onEvent: { name, line, _ in
                guard name.hasPrefix("agent-session-"), Self.surface(of: line) == surface else { return }
                handler.current?(name, line)
                if name == "agent-session-closed" { handler.set(nil) }
            },
            onClose: { [logger] reason in
                guard tells.withLock({ $0 }), let current = handler.current else { return }
                handler.set(nil)
                logger.info("agent attach connection ended: \(String(describing: reason), privacy: .public)")
                current("agent-session-closed", Data(#"{"event":"agent-session-closed","reason":"connection_lost"}"#.utf8))
            })
        let served: Served
        do {
            let identity = try await DaemonConnection.perform(IdentifyRequest(), on: transport, timeout: requestTimeout)
            guard identity.supports(mode.capability) else {
                transport.close()
                throw AgentSessionAttachError(code: "agent_session.unsupported", message: mode.unsupportedMessage)
            }
            served = Served(start: identity.supports(DaemonCapability.agentSessionStart.rawValue),
                            startNoCwd: identity.supports(DaemonCapability.agentSessionStartNoCwd.rawValue),
                            trust: identity.supports(DaemonCapability.agentSessionTrust.rawValue),
                            keyedReason: identity.supports(DaemonCapability.agentSessionStartKeyedReason.rawValue),
                            vmKind: identity.supports(DaemonCapability.agentSessionStartVMKind.rawValue),
                            model: identity.supports(DaemonCapability.agentSessionStartModel.rawValue),
                            trustVMKind: identity.supports(DaemonCapability.agentSessionTrustVMKind.rawValue),
                            children: identity.supports(DaemonCapability.agentSessionChildren.rawValue),
                            presence: identity.supports(DaemonCapability.agentSessionPresence.rawValue),
                            folders: identity.supports(DaemonCapability.agentSessionFolders.rawValue),
                            settings: identity.supports(DaemonCapability.agentSessionSettings.rawValue))
            _ = try await DaemonConnection.perform(
                // `agent-session-presence-v1` echoed: the daemon then streams presence (an app
                // from before it would end its attachment on an event it does not know).
                SetClientInfoRequest(name: mode.clientInfoName, kind: mode.clientInfoKind,
                                     capabilities: served.presence ? [DaemonCapability.agentSessionPresence.rawValue] : []),
                on: transport, timeout: requestTimeout)
        } catch {
            if quiet { quietLoss = true }
            transport.close()
            throw error
        }
        tells.withLock { $0 = true }
        newest = (ObjectIdentifier(transport), number, tells)
        return (transport, served)
    }

    private static func surface(of line: Data) -> UInt64? {
        ((try? JSONSerialization.jsonObject(with: line)) as? [String: Any])?["surface"].flatMap { ($0 as? NSNumber)?.uint64Value }
    }

    /// The `data` member of an `ok:true` response line, as JSON.
    static func data(of line: Data) -> Data {
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let data = object["data"], JSONSerialization.isValidJSONObject(data),
              let encoded = try? JSONSerialization.data(withJSONObject: data) else { return Data("{}".utf8) }
        return encoded
    }
}

/// A refused attach verb: the daemon's `error_code` (`agent_session.*`) and text.
public struct AgentSessionAttachError: Error, Sendable, Equatable {
    public var code: String
    public var message: String
    /// A typed refusal's facts (the response's `data`), when it has them.
    public var details: JSONValue? = nil

    public init(code: String, message: String, details: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.details = details
    }

    /// `agent_session.needs_keyed_start`: whether that machine's daemon says a keyed restart of
    /// its acpmux loses nothing (`safe_to_restart`); nil for any other refusal.
    public var keyedRestartSafe: Bool? {
        guard code == Self.needsKeyedStart else { return nil }
        return details?["safe_to_restart"]?.boolValue ?? false
    }

    public static let needsKeyedStart = "agent_session.needs_keyed_start"
    /// The refusal of a start on a teammate's Cloud machine (the card's New Cloud Machine, startRefusal.ts).
    public static let teamMachine = "agent_session.team_vm_blocked"

    /// The code the card sees: an owner check's refusal (`host_unverified`) on a machine its link
    /// says is a teammate's is that teammate refusal; every other code is as it came.
    public static func classified(_ code: String, teammate: Bool) -> String {
        code == "agent_session.host_unverified" && teammate ? teamMachine : code
    }
}

/// The current push handler, read on the transport's reader thread.
private final class HandlerBox: Sendable {
    private let lock = OSAllocatedUnfairLock<AgentSessionAttachClient.EventHandler?>(initialState: nil)
    var current: AgentSessionAttachClient.EventHandler? { lock.withLock { $0 } }
    func set(_ handler: AgentSessionAttachClient.EventHandler?) { lock.withLock { $0 = handler } }
    /// The handler, which is cleared: one caller tells it the attachment ended.
    func take() -> AgentSessionAttachClient.EventHandler? { lock.withLock { current in defer { current = nil }; return current } }
}
