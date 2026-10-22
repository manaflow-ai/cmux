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
    /// One push for the attachment: `agent-session-record`, `-permission` or `-closed`, with
    /// the line's JSON object.
    public typealias EventHandler = @Sendable (_ event: String, _ line: Data) -> Void

    /// How the daemon attachment is used. Observation has its own capability and command so a
    /// missing observer feature can never silently fall back to a writable attach.
    public enum Mode: Sendable, Equatable {
        case attach
        case observe

        var capability: String {
            switch self {
            case .attach: return DaemonCapabilities.shared.agentSessionAttach
            case .observe: return DaemonCapabilities.shared.agentSessionObserve
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

    public static let capability = DaemonCapabilities.shared.agentSessionAttach

    private let surface: UInt64
    private let mode: Mode
    private let endpoint: EndpointProvider
    private let requestTimeout: Duration
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "agent-attach")
    private var transport: LineTransport?
    private var connecting: Task<LineTransport, any Error>?
    private let handler = HandlerBox()
    private var closed = false
    /// The connected daemon serves `agent-session-start-v1` (read from its own `identify`).
    private var servesStart = false
    /// The connected daemon serves `agent-session-trust-v1`.
    private var servesTrust = false
    /// The connected daemon serves `agent-session-adopt-v1`.
    private var servesAdopt = false
    /// The connected daemon serves `agent-session-start-keyed-reason-v1`.
    private var servesKeyedReason = false
    /// The connected daemon serves `agent-session-children-v1`.
    private var servesChildren = false

    /// A start that needs the app's person key in that machine's acpmux (cx-0w0jj): `instance`
    /// is the acpmux run the app holds a key for, nil when it holds none.
    public struct PersonKey: Sendable, Equatable {
        public var instance: String?
        public init(instance: String?) { self.instance = instance }
    }

    /// `surface`: the tab's surface id in the daemon's store.
    public init(surface: UInt64, requestTimeout: Duration = .seconds(10), mode: Mode = .attach,
                endpoint: @escaping EndpointProvider) {
        self.surface = surface
        self.mode = mode
        self.endpoint = endpoint
        self.requestTimeout = requestTimeout
    }

    /// Subscribes and returns the attach page's JSON. Pushes go to `events` from then on. The
    /// chat's mode (the reply's `agentMode`, then each `agent-session-mode` push of a daemon with
    /// `agent-session-adopt-v1`) goes to ``AgentBypassSessions`` instead.
    public func attach(afterSeq: UInt64?, beforeSeq: UInt64?, limit: Int?, kinds: [String]?,
                       events: @escaping EventHandler) async throws -> Data {
        handler.set { event, line in
            guard event == "agent-session-mode" else { return events(event, line) }
            AgentBypassSessions.note(.push, of: line)
        }
        _ = try await liveTransport()
        var params = page(afterSeq, beforeSeq, limit, kinds)
        if servesAdopt { params["mode_events"] = true }
        let data = try await call(mode.command, params)
        AgentBypassSessions.note(.attachReply, of: data)
        return data
    }

    /// `agent-session-mode` (`agent-session-adopt-v1`) of tab `surface` over a connection of its
    /// own: the answer (``AgentBypassSessions/Carrier/answer``), nil from a daemon without the verb.
    /// The caller notes it only while its connection is current.
    public static func readMode(surface: UInt64, endpoint: @escaping EndpointProvider) async throws -> Data? {
        let client = AgentSessionAttachClient(surface: surface, endpoint: endpoint)
        let result: Result<Data?, any Error>
        do { result = .success(try await client.chatMode()) } catch { result = .failure(error) }
        await client.close()
        return try result.get()
    }

    /// The `agent-session-mode` answer; nil from a daemon without the verb.
    private func chatMode() async throws -> Data? {
        _ = try await liveTransport()
        return servesAdopt ? try await call("agent-session-mode", [:]) : nil
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
    public func start(cwd: String, harness: String?, homeConfirmed: Bool = false, personKey: PersonKey? = nil) async throws -> String {
        guard mode == .attach else {
            throw AgentSessionAttachError(code: Self.startUnsupported, message: "a read-only agent session cannot start a chat")
        }
        _ = try await liveTransport()
        guard servesStart else {
            throw AgentSessionAttachError(code: Self.startUnsupported, message: "the daemon does not serve agent session start")
        }
        var params: [String: any Sendable] = ["cwd": cwd]
        if let harness { params["harness"] = harness }
        if homeConfirmed { params["home_confirmed"] = true }
        if let personKey, servesKeyedReason {
            params["require_person_key"] = true
            if let instance = personKey.instance { params["person_instance"] = instance }
        }
        let data = try await call("agent-session-start", params)
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let session = object["session"] as? String, !session.isEmpty else {
            throw AgentSessionAttachError(code: "agent_session.refused", message: "agent-session-start answered no session")
        }
        return session
    }

    /// `agent-session-trust` (`agent-session-trust-v1`): the trust of `cwd` on the daemon's machine
    /// (acpmux's `acp.trust.get` reply), or with `level` the person's answer recorded there
    /// (`acp.trust.set`). Only the person's own answer is ever sent (the pane's relay).
    public func trust(cwd: String, level: String?, homeConfirmed: Bool = false) async throws -> Data {
        guard mode == .attach else {
            throw AgentSessionAttachError(code: Self.startUnsupported, message: "a read-only agent session cannot change trust")
        }
        _ = try await liveTransport()
        guard servesTrust else {
            throw AgentSessionAttachError(code: Self.startUnsupported, message: "the daemon does not serve agent session trust")
        }
        var params: [String: any Sendable] = ["cwd": cwd]
        if let level { params["level"] = level }
        if homeConfirmed { params["home_confirmed"] = true }
        return try await call("agent-session-trust", params)
    }

    /// A chat that already runs in the daemon's machine's acpmux, as `agent-session-adopt` bound it
    /// to the tab: `asking` is false for a mode that does not ask before acting (bypass).
    public struct Adopted: Sendable, Equatable {
        public let session: String
        public let mode: String?
        public let asking: Bool
    }

    /// `agent-session-adopt` (`agent-session-adopt-v1`): the daemon binds `session`, a chat of its
    /// own machine's acpmux (never a peer's mirror or the Home Chief's), to the tab, keeping its
    /// mode. A daemon that does not serve the verb is refused here (``startUnsupported``).
    public func adopt(session: String) async throws -> Adopted {
        guard mode == .attach else {
            throw AgentSessionAttachError(code: Self.startUnsupported, message: "a read-only agent session cannot adopt a chat")
        }
        _ = try await liveTransport()
        guard servesAdopt else {
            throw AgentSessionAttachError(code: Self.startUnsupported, message: "the daemon does not serve agent session adopt")
        }
        let data = try await call("agent-session-adopt", ["session": session])
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let bound = object["session"] as? String, bound == session else {
            throw AgentSessionAttachError(code: "agent_session.refused", message: "agent-session-adopt answered another session")
        }
        // An answer without `asking` never reads as asking.
        return Adopted(session: bound, mode: object["mode"] as? String, asking: object["asking"] as? Bool ?? false)
    }

    /// ``adopt(session:)`` on tab `surface` over a connection of its own, closed after the answer.
    public static func adopt(session: String, surface: UInt64, endpoint: @escaping EndpointProvider) async throws -> Adopted {
        let client = AgentSessionAttachClient(surface: surface, endpoint: endpoint)
        let result: Result<Adopted, any Error>
        do { result = .success(try await client.adopt(session: session)) } catch { result = .failure(error) }
        await client.close()
        return try result.get()
    }

    /// The code ``start(cwd:harness:)`` throws for a daemon without `agent-session-start-v1`.
    public static let startUnsupported = "agent_session.start_unsupported"

    public func prompt(id: String, text: String) async throws -> Data {
        try await call("agent-session-prompt", ["prompt_id": id, "text": text])
    }

    public func cancel() async throws {
        _ = try await call("agent-session-cancel", [:])
    }

    /// `agent-session-permission`, with the person's decision proof of a relayed allow when there
    /// is one (cx-0q7o): the daemon passes it to acpmux unchanged, and acpmux decides.
    public func permission(id: String, option: String, decisionNonce: String? = nil, personDecision: String? = nil) async throws {
        var params: [String: any Sendable] = ["permission_id": id, "option_id": option]
        if let decisionNonce, let personDecision {
            params["decision_nonce"] = decisionNonce
            params["person_decision"] = personDecision
        }
        _ = try await call("agent-session-permission", params)
    }

    public func detach() async {
        _ = try? await call("agent-session-detach", [:])
    }

    /// `agent-session-children` (`agent-session-children-v1`): the chats the attached tab's session
    /// started on the daemon's machine (`{sessions}`, acpmux summaries); the attachment then
    /// streams their changes too. A daemon without the verb lists none.
    public func children() async throws -> Data {
        _ = try await liveTransport()
        guard servesChildren else { return Data(#"{"sessions":[]}"#.utf8) }
        return try await call("agent-session-children", [:])
    }

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

    /// One verb on the tab; the result's `data` as JSON, or the daemon's refusal.
    private func call(_ cmd: String, _ params: [String: any Sendable]) async throws -> Data {
        let transport = try await liveTransport()
        var object = params
        object["cmd"] = cmd
        object["surface"] = surface
        // Integers stay integers (the daemon reads u64 seqs and surface ids).
        let fields = try JSONSerialization.data(withJSONObject: object)
        let response: LineTransport.Response
        do {
            response = try await transport.request(cmd: cmd, timeout: requestTimeout) { id in
                Data(#"{"id":\#(id),"#.utf8) + fields.dropFirst()
            }
        } catch DaemonError.command(_, let message, let code, let details, _) {
            throw AgentSessionAttachError(code: code ?? "agent_session.refused", message: message, details: details)
        }
        return Self.data(of: response.line)
    }

    private func liveTransport() async throws -> LineTransport {
        if closed { throw AgentSessionAttachError(code: "agent_session.closed", message: "closed") }
        if let transport, !transport.isClosed { return transport }
        transport = nil
        if let connecting { return try await connecting.value }
        let task = Task { try await self.connect() }
        connecting = task
        defer { connecting = nil }
        let transport = try await task.value
        if closed {
            transport.close()
            throw AgentSessionAttachError(code: "agent_session.closed", message: "closed")
        }
        self.transport = transport
        return transport
    }

    private func connect() async throws -> LineTransport {
        let endpoint = try await self.endpoint()
        let transport = try LineTransport(path: endpoint.socketPath)
        let handler = handler
        let surface = surface
        transport.start(
            onEvent: { name, line, _ in
                guard name.hasPrefix("agent-session-"), Self.surface(of: line) == surface else { return }
                handler.current?(name, line)
                if name == "agent-session-closed" { handler.set(nil) }
            },
            onClose: { [logger] reason in
                guard let current = handler.current else { return }
                handler.set(nil)
                logger.info("agent attach connection ended: \(String(describing: reason), privacy: .public)")
                current("agent-session-closed", Data(#"{"event":"agent-session-closed","reason":"connection_lost"}"#.utf8))
            })
        do {
            let identity = try await DaemonConnection.perform(IdentifyRequest(), on: transport, timeout: requestTimeout)
            guard identity.supports(mode.capability) else {
                transport.close()
                throw AgentSessionAttachError(code: "agent_session.unsupported", message: mode.unsupportedMessage)
            }
            servesStart = identity.supports(DaemonCapabilities.shared.agentSessionStart)
            servesTrust = identity.supports(DaemonCapabilities.shared.agentSessionTrust)
            servesAdopt = identity.supports(DaemonCapabilities.shared.agentSessionAdopt)
            servesKeyedReason = identity.supports(DaemonCapabilities.shared.agentSessionStartKeyedReason)
            servesChildren = identity.supports(DaemonCapabilities.shared.agentSessionChildren)
            _ = try await DaemonConnection.perform(
                SetClientInfoRequest(name: mode.clientInfoName, kind: mode.clientInfoKind, capabilities: []),
                on: transport, timeout: requestTimeout)
        } catch {
            transport.close()
            throw error
        }
        return transport
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
}

/// The current push handler, read on the transport's reader thread.
private final class HandlerBox: Sendable {
    private let lock = OSAllocatedUnfairLock<AgentSessionAttachClient.EventHandler?>(initialState: nil)
    var current: AgentSessionAttachClient.EventHandler? { lock.withLock { $0 } }
    func set(_ handler: AgentSessionAttachClient.EventHandler?) { lock.withLock { $0 = handler } }
}
