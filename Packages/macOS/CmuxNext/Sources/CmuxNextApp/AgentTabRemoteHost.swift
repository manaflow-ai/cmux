import CmuxNextAgentPane
import CmuxNextDaemon
import Foundation

/// The pane host of an agent chat tab whose session runs on another machine: the tab's own
/// session daemon (the remote store that lists it, `agent-session-attach-v1`) carries the chat.
/// Each connection of the page gets a fresh daemon attachment (``RemoteAcpmuxWire`` over
/// ``AgentSessionAttachClient``); the page never reaches that machine's acpmux directly.
nonisolated struct AgentTabRemoteHost: AgentPaneHostProviding {
    let surface: UInt64
    let session: String
    let machine: String
    let endpoint: AgentSessionAttachClient.EndpointProvider

    func handshake(sessionId: String?) async throws -> AgentPaneHandshake {
        let route = AgentPaneRemoteRoute(machine: machine) { [surface, session, endpoint] in
            let client = AgentSessionAttachClient(surface: surface, endpoint: endpoint)
            return RemoteAcpmuxWire(client: AgentTabRemoteClient(client: client), session: session)
        }
        var handshake = AgentPaneHandshake.acpmux(.remote(route), sessionId: session)
        // The chat exists on its machine: never a fallback to another one.
        handshake.sessionMustExist = true
        return handshake
    }
}

/// ``AgentSessionAttachClient`` as the pane's ``AgentSessionRemoteClient``.
nonisolated struct AgentTabRemoteClient: AgentSessionRemoteClient {
    let client: AgentSessionAttachClient

    func attach(_ page: AgentSessionPage, events handler: @escaping @Sendable (AgentSessionRemoteEvent) -> Void) async throws -> Data {
        try await mapped {
            try await client.attach(afterSeq: page.afterSeq, beforeSeq: page.beforeSeq, limit: page.limit, kinds: page.kinds) { event, line in
                handler(Self.event(event, line))
            }
        }
    }

    func events(_ page: AgentSessionPage) async throws -> Data {
        try await mapped { try await client.events(afterSeq: page.afterSeq, beforeSeq: page.beforeSeq, limit: page.limit, kinds: page.kinds) }
    }

    func prompt(id: String, text: String) async throws -> Data {
        try await mapped { try await client.prompt(id: id, text: text) }
    }

    func cancel() async throws { _ = try await mapped { try await client.cancel(); return Data() } }

    func permission(id: String, option: String) async throws {
        _ = try await mapped { try await client.permission(id: id, option: option); return Data() }
    }

    func detach() async { await client.detach() }

    func close() async { await client.close() }

    /// A daemon push as the pane's event: the record or request object, or the close reason.
    static func event(_ name: String, _ line: Data) -> AgentSessionRemoteEvent {
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
    private func mapped(_ work: () async throws -> Data) async throws -> Data {
        do {
            return try await work()
        } catch let error as AgentSessionAttachError {
            throw AgentSessionRemoteError(code: error.code, message: error.message)
        }
    }
}
