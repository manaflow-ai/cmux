import CmuxNextAgentPane
import CmuxNextDaemon
import Foundation

/// The pane host of an agent chat tab whose session runs on another machine: the tab's own
/// session daemon (the remote store that lists it, `agent-session-attach-v1`) carries the chat.
/// Each connection of the page gets a fresh daemon attachment (``RemoteAcpmuxWire`` over
/// ``AgentSessionAttachClient``); the page never reaches that machine's acpmux directly.
nonisolated struct AgentTabRemoteHost: AgentPaneHostProviding {
    let surface: UInt64
    /// The chat's session; nil for a new chat that ``start`` starts on its machine first.
    let session: String?
    let machine: String
    let endpoint: AgentSessionAttachClient.EndpointProvider
    /// The keyed restart of the machine's acpmux (an SSH machine, or a paired server on the ssh
    /// route); nil where the app has no exec channel of its own (cx-0q7o).
    var approvals: AgentPaneRemoteApprovals?
    /// The tab this app opened on that machine as the store lists it: its surface there, and its
    /// session once its first send started one. Never starts one.
    var existing: (@Sendable () async throws -> (surface: UInt64, session: String?)?)?
    /// Starts a new chat in the machine's own acpmux (`agent-session-start`, policy `ask`) in the
    /// page's folder with the page's agent (nil: the tab's own) and answers the tab's surface there
    /// and the session (``AgentTabStore/startRemoteChat``). Called only by the page's first send.
    var start: (@Sendable (_ cwd: String?, _ harness: String?) async throws -> AgentTabRemoteStart.Started)?

    func handshake(sessionId: String?) async throws -> AgentPaneHandshake {
        var surface = surface
        var session = sessionId ?? self.session
        // The tab this run opened may have been provisional when this host was made: the store's
        // surface and the session come from the tab (also on a reconnect after the first send).
        if let existing {
            if let found = try await existing() {
                (surface, session) = (found.surface, found.session ?? session)
            } else if session != nil {
                // A known chat whose tab the store does not list: never attach through a surface
                // the store has not confirmed (the provisional one this host was made with).
                throw AgentRemoteStartRefusal(code: "agent_session.unknown_tab", machine: machine)
            }
        }
        let route: AgentPaneRemoteRoute
        if let session {
            route = AgentPaneRemoteRoute(machine: machine, approvals: approvals) { [surface, session, endpoint] in
                let client = AgentSessionAttachClient(surface: surface, endpoint: endpoint)
                return RemoteAcpmuxWire(client: AgentTabRemoteClient(client: client), session: session)
            }
        } else if let start {
            // A new chat: nothing runs on that machine until the page's first send (cx-k21v). The
            // page shows the New Tab page or an empty chat; its `session/new` starts the chat.
            route = AgentPaneRemoteRoute(machine: machine, approvals: approvals) { [endpoint] in
                RemoteAcpmuxWire { cwd, harness in
                    let started: AgentTabRemoteStart.Started
                    do {
                        started = try await start(cwd, harness)
                    } catch let refusal as AgentRemoteStartRefusal {
                        throw AgentSessionRemoteError(code: refusal.code, message: refusal.userMessage)
                    }
                    let client = AgentSessionAttachClient(surface: started.surface, endpoint: endpoint)
                    return (AgentTabRemoteClient(client: client), started.session)
                }
            }
        } else {
            throw AgentRemoteStartRefusal.startUnsupported(machine: machine)
        }
        var handshake = AgentPaneHandshake.acpmux(.remote(route), sessionId: session)
        // The chat exists on its machine: never a fallback to another one.
        if session != nil { handshake.sessionMustExist = true }
        // The composer's machine chip names the chat's machine, not this Mac (cx-k21v).
        handshake.machineName = machine
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

    func permission(id: String, option: String, decisionNonce: String?, personDecision: String?) async throws {
        _ = try await mapped {
            try await client.permission(id: id, option: option, decisionNonce: decisionNonce, personDecision: personDecision)
            return Data()
        }
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
