public import CmuxNextDaemon
public import Foundation

/// ``AgentSessionAttachClient`` (the owning session daemon's attach) as the pane's ``AgentSessionRemoteClient``.
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
            try await client.attach(afterSeq: page.afterSeq, beforeSeq: page.beforeSeq, limit: page.limit, kinds: page.kinds,
                                    maxBytes: page.maxBytes) { event, line in
                handler(Self.event(event, line))
            }
        }
    }

    public func events(_ page: AgentSessionPage) async throws -> Data {
        try await mapped {
            try await client.events(afterSeq: page.afterSeq, beforeSeq: page.beforeSeq, limit: page.limit, kinds: page.kinds,
                                    maxBytes: page.maxBytes)
        }
    }

    public func prompt(id: String, text: String) async throws -> Data {
        try await mapped { try await client.prompt(id: id, text: text) }
    }

    public func prompt(id: String, content: Data) async throws -> Data {
        try await mapped { try await client.prompt(id: id, content: content) }
    }

    public func prompt(id: String, text: String, steer: Bool) async throws -> Data {
        try await mapped { try await client.prompt(id: id, text: text, steer: steer) }
    }

    public func prompt(id: String, content: Data, steer: Bool) async throws -> Data {
        try await mapped { try await client.prompt(id: id, content: content, steer: steer) }
    }

    public func queueApprove(promptID: String, turnID: String, revision: UInt64) async throws -> Data {
        try await mapped { try await client.queueApprove(promptID: promptID, turnID: turnID, revision: revision) }
    }

    public func queueDecline(promptID: String) async throws -> Data {
        try await mapped { try await client.queueDecline(promptID: promptID) }
    }

    public func cancel() async throws { _ = try await mapped { try await client.cancel(); return Data() } }

    public func permission(id: String, option: String, answers: Data?, annotations: Data?, decisionNonce: String?,
                    personDecision: String?) async throws {
        _ = try await mapped {
            try await client.permission(id: id, option: option, answers: answers, annotations: annotations,
                                        decisionNonce: decisionNonce, personDecision: personDecision)
            return Data()
        }
    }

    public func detach() async { await client.detach() }

    public func children() async throws -> Data { try await mapped { try await client.children() } }

    public func media(path: String) async throws -> Data { try await mapped { try await client.media(path: path) } }

    public func mediaRange(path: String, offset: Int, length: Int, handle: String?) async throws -> Data {
        try await mapped { try await client.mediaRange(path: path, offset: offset, length: length, handle: handle) }
    }

    public func typing(_ on: Bool) async throws { _ = try await mapped { try await client.typing(on); return Data() } }

    public func view(_ visible: Bool) async throws { _ = try await mapped { try await client.view(visible); return Data() } }

    public func setModel(_ modelId: String) async throws -> Data { try await mapped { try await client.setModel(modelId) } }

    public func setMode(_ modeId: String) async throws -> Data { try await mapped { try await client.setMode(modeId) } }

    public func setConfig(id configId: String, value: String) async throws -> Data {
        try await mapped { try await client.setConfig(id: configId, value: value) }
    }

    public func context() async throws -> Data { try await mapped { try await client.context() } }

    public func setContextOverride(scope: String, text: String?, partId: String?) async throws -> Data {
        try await mapped { try await client.setContextOverride(scope: scope, text: text, partId: partId) }
    }

    /// An observation never signs the chat's agent in.
    public func servesLogin() async -> Bool {
        guard mode != .observe else { return false }
        return await client.servesLogin()
    }

    public func login(_ op: String, _ fields: [String: String]) async throws -> Data {
        try await mapped { try await client.login(op, fields) }
    }

    public func btw(_ question: String) async throws -> Data { try await mapped { try await client.btw(question) } }

    /// An observation never opens a side chat.
    public func servesSide() async -> Bool {
        guard mode != .observe else { return false }
        return await client.servesSide()
    }

    public func side(throughSeq: Int?, prompt: String?, promptID: String) async throws -> Data {
        try await mapped { try await client.side(throughSeq: throughSeq, prompt: prompt, promptID: promptID) }
    }

    public func close() async { await client.close() }

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
        case "agent-session-presence": return .presence(member("presence"))
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

extension AgentTabRemoteClient {
    /// The tab's surface on its machine as that machine's store lists it now (a new chat's tab may
    /// have been provisional when its host was made).
    public typealias TabSurface = @Sendable () async throws -> UInt64

    /// The folder trust question of the tab's machine (cx-1bhjj, ``RemoteAcpmuxWire/Trust``): one
    /// `agent-session-trust` call on a fresh attachment to `tab()`, gated by `ownerLink` there.
    public static func trust(tab: @escaping TabSurface, reconnect: AgentSessionAttachClient.Reconnect?,
                             endpoint: @escaping AgentSessionAttachClient.EndpointProvider,
                             ownerLink: AgentSessionAttachClient.OwnerLink?) -> RemoteAcpmuxWire.Trust {
        { cwd, level, home in
            try await once(tab: tab, reconnect: reconnect, endpoint: endpoint) { client in
                try await client.trust(cwd: cwd, level: level, homeConfirmed: home, ownerLink: ownerLink)
            }
        }
    }

    /// A new chat's agent sign-in on the tab's machine before it has a session (hq#11225,
    /// ``RemoteAcpmuxWire/MachineLogin``): one `agent-session-login` step on a fresh attachment to
    /// `tab()`, gated there as its start is (the same owner answer, `vm_kind: "owner"`).
    public static func machineLogin(tab: @escaping TabSurface, reconnect: AgentSessionAttachClient.Reconnect?,
                                    endpoint: @escaping AgentSessionAttachClient.EndpointProvider,
                                    ownerLink: AgentSessionAttachClient.OwnerLink?) -> RemoteAcpmuxWire.MachineLogin {
        { op, fields in
            try await once(tab: tab, reconnect: reconnect, endpoint: endpoint) { client in
                try await client.machineLogin(op, fields, ownerLink: ownerLink)
            }
        }
    }

    /// `work` on a fresh attachment to `tab()`, closed after, with the daemon's refusal as the pane's.
    private static func once(tab: TabSurface, reconnect: AgentSessionAttachClient.Reconnect?,
                             endpoint: @escaping AgentSessionAttachClient.EndpointProvider,
                             _ work: (AgentSessionAttachClient) async throws -> Data) async throws -> Data {
        let client = AgentSessionAttachClient(surface: try await tab(), reconnect: reconnect, endpoint: endpoint)
        let answer: Result<Data, any Error>
        do { answer = .success(try await AgentTabRemoteClient(client: client, mode: .attach).mapped { try await work(client) }) } catch { answer = .failure(error) }
        await client.close()
        return try answer.get()
    }
}
