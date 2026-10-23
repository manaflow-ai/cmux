public import CmuxNextDaemon
public import Foundation

/// ``AgentSessionAttachClient`` as the pane's ``AgentSessionRemoteClient``.
public nonisolated struct AgentTabRemoteClient: AgentSessionRemoteClient {
    public let client: AgentSessionAttachClient
    public let mode: AgentSessionAttachClient.Mode

    public init(client: AgentSessionAttachClient, mode: AgentSessionAttachClient.Mode) {
        self.client = client
        self.mode = mode
    }

    public var isReadOnly: Bool { mode == .observe }

    public func attach(_ page: AgentSessionPage, events handler: @escaping @Sendable (AgentSessionRemoteEvent) -> Void) async throws -> Data {
        try await mapped {
            try await client.attach(afterSeq: page.afterSeq, beforeSeq: page.beforeSeq, limit: page.limit, kinds: page.kinds) { event, line in
                handler(Self.event(event, line))
            }
        }
    }

    public func events(_ page: AgentSessionPage) async throws -> Data {
        try await mapped { try await client.events(afterSeq: page.afterSeq, beforeSeq: page.beforeSeq, limit: page.limit, kinds: page.kinds) }
    }

    public func prompt(id: String, text: String) async throws -> Data {
        try await mapped { try await client.prompt(id: id, text: text) }
    }

    public func cancel() async throws { _ = try await mapped { try await client.cancel(); return Data() } }

    public func permission(id: String, option: String, decisionNonce: String?, personDecision: String?) async throws {
        _ = try await mapped {
            try await client.permission(id: id, option: option, decisionNonce: decisionNonce, personDecision: personDecision)
            return Data()
        }
    }

    public func detach() async { await client.detach() }

    public func children() async throws -> Data { try await mapped { try await client.children() } }

    public func close() async { await client.close() }

    /// A daemon push as the pane's event: the record or request object, or the close reason.
    public static func event(_ name: String, _ line: Data) -> AgentSessionRemoteEvent {
        let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] ?? [:]
        let member = { (key: String) -> Data in
            guard let value = object[key], JSONSerialization.isValidJSONObject(value),
                  let data = try? JSONSerialization.data(withJSONObject: value) else { return Data("{}".utf8) }
            return data
        }
        switch name {
        case "agent-session-record": return .record(member("record"))
        case "agent-session-permission": return .permission(member("request"))
        case "agent-session-changed": return .changed(member("change"))
        default: return .closed(object["reason"] as? String ?? "closed")
        }
    }

    /// The daemon's refusal as the pane's error (its `agent_session.*` code reaches the page).
    public func mapped(_ work: () async throws -> Data) async throws -> Data {
        do {
            return try await work()
        } catch let error as AgentSessionAttachError {
            throw AgentSessionRemoteError(code: error.code, message: error.message)
        }
    }
}
