import Foundation

/// The acpmux requests the chat pane uses, as a seam so the session model can be tested
/// against a fake daemon.
public protocol AcpmuxSessionAPI: Sendable {
    /// The authenticated loopback WebSocket endpoint for browser clients.
    func webSocketEndpoint() async throws -> AcpmuxWebSocketEndpoint
    /// Daemon notifications. Finishes when the connection closes.
    var notifications: AsyncStream<JSONRPCNotification> { get }
    /// `_acpmux/watch {enabled:true}`; returns the current session list.
    func watch() async throws -> [AcpmuxSessionSummary]
    /// `_acpmux/attach`, asking for transcript records only (older daemons ignore `kinds`).
    func attach(sessionId: String, afterSeq: Int?, limit: Int) async throws -> AcpmuxAttachResult
    /// `_acpmux/events`: records with `seq > afterSeq`, at most `limit`.
    func events(sessionId: String, afterSeq: Int, limit: Int) async throws -> [AcpmuxEventRecord]
    /// `_acpmux/events {beforeSeq, kinds: ["transcript"]}`: the newest `limit` transcript
    /// records before `beforeSeq`, and whether older ones exist (current acpmux).
    func eventsBefore(sessionId: String, beforeSeq: Int, limit: Int) async throws -> (events: [AcpmuxEventRecord], hasMore: Bool)
    /// `_acpmux/detach`.
    func detach(sessionId: String) async throws
    /// `session/new` with `_meta.acpmux.harness`; returns the new session id.
    func newSession(harness: String?, cwd: String?) async throws -> String
    /// `session/prompt`. Returns when the prompt's turn ends.
    func prompt(sessionId: String, text: String, promptId: String, delivery: String?) async throws -> JSONValue
    /// `session/cancel`, sent as a notification.
    func cancel(sessionId: String) async throws
    /// `_acpmux/permission_respond`. A `nil` option cancels the request.
    func respondToPermission(sessionId: String, permissionId: String, optionId: String?) async throws
    /// `_acpmux/queue_steer`: delivers a queued prompt into the running turn now.
    func steerQueued(sessionId: String, promptId: String) async throws
    /// `_acpmux/queue {remove:true}`.
    func removeQueued(sessionId: String, promptId: String) async throws
    /// `_acpmux/harnesses` merged with `_acpmux/models`.
    func harnessCatalog() async throws -> AcpmuxHarnessCatalog
    /// `session/set_model`.
    func setModel(sessionId: String, modelId: String) async throws
    /// `session/set_mode`, when the harness exposes ACP modes.
    func setMode(sessionId: String, modeId: String) async throws
    /// `session/set_config_option`, used for reasoning effort and similar options.
    func setConfigOption(sessionId: String, configId: String, value: JSONValue) async throws
    /// Closes the connection.
    func close() async
}

/// A daemon WebSocket endpoint safe to hand to a local web view for one launch.
public struct AcpmuxWebSocketEndpoint: Sendable, Equatable, Codable {
    public let endpoint: String
    public let token: String

    public init(endpoint: String, token: String) {
        self.endpoint = endpoint
        self.token = token
    }
}

public extension AcpmuxSessionAPI {
    func webSocketEndpoint() async throws -> AcpmuxWebSocketEndpoint {
        throw JSONRPCError(code: -32601, message: "WebSocket endpoint is unavailable")
    }

    func setMode(sessionId _: String, modeId _: String) async throws {
        throw JSONRPCError(code: -32601, message: "session/set_mode is unavailable")
    }

    func setConfigOption(sessionId _: String, configId _: String, value _: JSONValue) async throws {
        throw JSONRPCError(code: -32601, message: "session/set_config_option is unavailable")
    }
}

/// ``AcpmuxSessionAPI`` over a live ``JSONRPCClient``.
public struct AcpmuxRPCSessionAPI: AcpmuxSessionAPI {
    private let client: JSONRPCClient

    /// Wraps a connected client. Call ``initialize(clientName:version:)`` before other requests.
    public init(client: JSONRPCClient) {
        self.client = client
    }

    public var notifications: AsyncStream<JSONRPCNotification> { client.notifications }

    public func webSocketEndpoint() async throws -> AcpmuxWebSocketEndpoint {
        let status = try await client.request("_acpmux/status", params: [String: String](), as: StatusResult.self)
        guard let webURL = status.webURL,
              var components = URLComponents(string: webURL),
              let token = components.queryItems?.first(where: { $0.name == "token" })?.value,
              !token.isEmpty,
              let scheme = components.scheme else {
            throw JSONRPCError(code: -32001, message: "acpmux did not publish an authenticated WebSocket endpoint")
        }
        components.scheme = scheme == "https" ? "wss" : "ws"
        components.queryItems = components.queryItems?.filter { $0.name != "token" }
        guard let endpoint = components.url?.absoluteString else {
            throw JSONRPCError(code: -32001, message: "acpmux published an invalid WebSocket endpoint")
        }
        return AcpmuxWebSocketEndpoint(endpoint: endpoint, token: token)
    }

    /// Sends `initialize`.
    public func initialize(clientName: String, version: String) async throws {
        _ = try await client.request("initialize", params: InitializeParams(
            protocolVersion: 1,
            clientInfo: .init(name: clientName, version: version)
        ))
    }

    public func watch() async throws -> [AcpmuxSessionSummary] {
        try await client.request("_acpmux/watch", params: ["enabled": true], as: SessionsResult.self).sessions
    }

    public func attach(sessionId: String, afterSeq: Int?, limit: Int) async throws -> AcpmuxAttachResult {
        try await client.request(
            "_acpmux/attach",
            params: CursorParams(sessionId: sessionId, afterSeq: afterSeq, limit: limit, kinds: ["transcript"]),
            as: AcpmuxAttachResult.self
        )
    }

    public func eventsBefore(sessionId: String, beforeSeq: Int, limit: Int) async throws -> (events: [AcpmuxEventRecord], hasMore: Bool) {
        let result = try await client.request(
            "_acpmux/events",
            params: CursorParams(sessionId: sessionId, beforeSeq: beforeSeq, limit: limit, kinds: ["transcript"]),
            as: EventsResult.self
        )
        return (result.events, result.hasMore ?? !result.events.isEmpty)
    }

    public func events(sessionId: String, afterSeq: Int, limit: Int) async throws -> [AcpmuxEventRecord] {
        try await client.request(
            "_acpmux/events",
            params: CursorParams(sessionId: sessionId, afterSeq: afterSeq, limit: limit),
            as: EventsResult.self
        ).events
    }

    public func detach(sessionId: String) async throws {
        _ = try await client.request("_acpmux/detach", params: ["sessionId": sessionId])
    }

    public func newSession(harness: String?, cwd: String?) async throws -> String {
        var params: [String: JSONValue] = ["mcpServers": .array([])]
        if let cwd { params["cwd"] = .string(cwd) }
        if let harness { params["_meta"] = .object(["acpmux": .object(["harness": .string(harness)])]) }
        let result = try await client.request("session/new", params: JSONValue.object(params))
        guard let sessionId = result["sessionId"]?.stringValue else {
            throw JSONRPCError(code: -32603, message: "session/new returned no sessionId")
        }
        return sessionId
    }

    public func prompt(sessionId: String, text: String, promptId: String, delivery: String?) async throws -> JSONValue {
        var acpmux: [String: JSONValue] = ["promptId": .string(promptId)]
        if let delivery { acpmux["delivery"] = .string(delivery) }
        let params: JSONValue = .object([
            "sessionId": .string(sessionId),
            "prompt": .array([.object(["type": .string("text"), "text": .string(text)])]),
            "_meta": .object(["acpmux": .object(acpmux)]),
        ])
        return try await client.request("session/prompt", params: params)
    }

    public func cancel(sessionId: String) async throws {
        try await client.notify("session/cancel", params: ["sessionId": sessionId])
    }

    public func respondToPermission(sessionId: String, permissionId: String, optionId: String?) async throws {
        var params = ["sessionId": sessionId, "permissionId": permissionId]
        if let optionId { params["optionId"] = optionId }
        _ = try await client.request("_acpmux/permission_respond", params: params)
    }

    public func steerQueued(sessionId: String, promptId: String) async throws {
        _ = try await client.request("_acpmux/queue_steer", params: ["sessionId": sessionId, "promptId": promptId])
    }

    public func removeQueued(sessionId: String, promptId: String) async throws {
        _ = try await client.request("_acpmux/queue", params: JSONValue.object([
            "sessionId": .string(sessionId),
            "promptId": .string(promptId),
            "remove": .bool(true),
        ]))
    }

    public func harnessCatalog() async throws -> AcpmuxHarnessCatalog {
        async let harnesses = client.request("_acpmux/harnesses", params: [String: String]())
        let models = (try? await client.request("_acpmux/models", params: [String: String]())) ?? .null
        return AcpmuxHarnessCatalog(harnessesResult: try await harnesses, modelsResult: models)
    }

    public func setModel(sessionId: String, modelId: String) async throws {
        _ = try await client.request("session/set_model", params: ["sessionId": sessionId, "modelId": modelId])
    }

    public func setMode(sessionId: String, modeId: String) async throws {
        _ = try await client.request("session/set_mode", params: ["sessionId": sessionId, "modeId": modeId])
    }

    public func setConfigOption(sessionId: String, configId: String, value: JSONValue) async throws {
        _ = try await client.request("session/set_config_option", params: JSONValue.object([
            "sessionId": .string(sessionId),
            "configId": .string(configId),
            "value": value,
        ]))
    }

    public func close() async {
        await client.close()
    }

    private struct InitializeParams: Encodable, Sendable {
        struct ClientInfo: Encodable, Sendable {
            var name: String
            var version: String
        }
        var protocolVersion: Int
        var clientCapabilities: [String: String] = [:]
        var clientInfo: ClientInfo
    }

    private struct CursorParams: Encodable, Sendable {
        var sessionId: String
        var afterSeq: Int?
        var beforeSeq: Int?
        var limit: Int
        var kinds: [String]?
    }

    private struct SessionsResult: Decodable, Sendable {
        var sessions: [AcpmuxSessionSummary]
    }

    private struct StatusResult: Decodable, Sendable {
        var webURL: String?
        enum CodingKeys: String, CodingKey { case webURL = "webUrl" }
    }

    private struct EventsResult: Decodable, Sendable {
        var events: [AcpmuxEventRecord]
        var hasMore: Bool?
    }
}
