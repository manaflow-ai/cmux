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

    public static let capability = DaemonCapabilities.shared.agentSessionAttach

    private let surface: UInt64
    private let endpoint: EndpointProvider
    private let requestTimeout: Duration
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "agent-attach")
    private var transport: LineTransport?
    private var connecting: Task<LineTransport, any Error>?
    private let handler = HandlerBox()
    private var closed = false

    /// `surface`: the tab's surface id in the daemon's store.
    public init(surface: UInt64, requestTimeout: Duration = .seconds(10), endpoint: @escaping EndpointProvider) {
        self.surface = surface
        self.endpoint = endpoint
        self.requestTimeout = requestTimeout
    }

    /// Subscribes and returns the attach page's JSON. Pushes go to `events` from then on.
    public func attach(afterSeq: UInt64?, beforeSeq: UInt64?, limit: Int?, kinds: [String]?,
                       events: @escaping EventHandler) async throws -> Data {
        handler.set(events)
        return try await call("agent-session-attach", page(afterSeq, beforeSeq, limit, kinds))
    }

    public func events(afterSeq: UInt64?, beforeSeq: UInt64?, limit: Int?, kinds: [String]?) async throws -> Data {
        try await call("agent-session-events", page(afterSeq, beforeSeq, limit, kinds))
    }

    public func prompt(id: String, text: String) async throws -> Data {
        try await call("agent-session-prompt", ["prompt_id": id, "text": text])
    }

    public func cancel() async throws {
        _ = try await call("agent-session-cancel", [:])
    }

    public func permission(id: String, option: String) async throws {
        _ = try await call("agent-session-permission", ["permission_id": id, "option_id": option])
    }

    public func detach() async {
        _ = try? await call("agent-session-detach", [:])
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
        } catch DaemonError.command(_, let message, let code, _, _) {
            throw AgentSessionAttachError(code: code ?? "agent_session.refused", message: message)
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
            guard identity.supports(Self.capability) else {
                transport.close()
                throw AgentSessionAttachError(code: "agent_session.unsupported", message: "the daemon does not serve agent session attach")
            }
            _ = try await DaemonConnection.perform(
                SetClientInfoRequest(name: "cmux-next agent attach", kind: "agent-session-attach", capabilities: []),
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
}

/// The current push handler, read on the transport's reader thread.
private final class HandlerBox: Sendable {
    private let lock = OSAllocatedUnfairLock<AgentSessionAttachClient.EventHandler?>(initialState: nil)
    var current: AgentSessionAttachClient.EventHandler? { lock.withLock { $0 } }
    func set(_ handler: AgentSessionAttachClient.EventHandler?) { lock.withLock { $0 = handler } }
}
