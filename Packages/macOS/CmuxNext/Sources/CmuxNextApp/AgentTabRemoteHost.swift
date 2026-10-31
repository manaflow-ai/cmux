import CmuxNextAgentPane
import CmuxNextCloud
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
    let hostID: String
    /// The daemon's store host (`registry:<id>`, ``AgentTabStore/registryHost(of:)``), which opening a
    /// remote child checks its lineage under; the wire notes the daemon's links under it too.
    var linksHost: String?
    let endpoint: AgentSessionAttachClient.EndpointProvider
    /// Asked when a connection to the machine fails: reconnects a down link and tries once more
    /// (``AgentPaneMachineLink/reconnecting(machine:)``); nil, never.
    var reconnect: AgentSessionAttachClient.Reconnect?
    /// `.observe` opens the remote session as a read-only viewer with no mutation fallback.
    var mode: AgentSessionAttachClient.Mode = .attach
    /// Present only for a Cloud VM resolved by the native machine registry.
    var cloudMachineID: String?
    var cloudAccount: [String?]?
    var cloudCredentialRecoveryAvailable = false
    /// The machine's daemon answers the folder trust question (`agent-session-trust-v1`).
    var servesTrust = false
    /// The machine's daemon says whether a keyed acpmux restart loses nothing
    /// (`agent-session-start-keyed-reason-v1`, cx-0w0jj).
    var servesKeyedReason = false
    /// A Cloud machine's link owner answer (``ownerLink(appLink:link:)``), read at each trust call
    /// and never kept. Nil for a machine that is not a Cloud machine.
    var ownerLink: AgentSessionAttachClient.OwnerLink?

    /// The owner answer of the link a Cloud machine's calls go over: the app link's own
    /// (``CloudLinkSession/ownerLink``) or the legacy link's (``CloudMachineLink/ownerLink``).
    static func ownerLink(appLink: CloudLinkSession?, link: CloudMachineLink?) -> AgentSessionAttachClient.OwnerLink {
        if let appLink { return { await appLink.ownerLink } }
        return { await link?.ownerLink }
    }

    /// Whether the link a Cloud machine's calls go over says the machine is a teammate's (the app
    /// link's own answer, or the legacy link's): only names a refused start, never grants one.
    static func teammate(appLink: CloudLinkSession?, link: CloudMachineLink?) -> AgentTabRemoteStart.Teammate {
        if let appLink { return { await appLink.callerIsTeammate } }
        return { await link?.callerIsTeammate ?? false }
    }
    /// The keyed restart of the machine's acpmux (an SSH machine, or a paired server on the ssh
    /// route); nil where the app has no exec channel of its own (cx-0q7o).
    var approvals: AgentPaneRemoteApprovals?
    /// The tab this app opened on that machine as the store lists it: its surface there, and its
    /// session once its first send started one. Never starts one.
    var existing: (@Sendable () async throws -> (surface: UInt64, session: String?)?)?
    /// Starts a new chat in the machine's own acpmux (`agent-session-start`, policy `ask`) in the
    /// page's folder with the page's agent (nil: the tab's own) and answers the tab's surface there
    /// and the session (``AgentTabStore/startRemoteChat``). Called only by the page's first send.
    var start: (@Sendable (_ cwd: String?, _ harness: String?, _ model: String?, _ personKey: AgentSessionAttachClient.PersonKey?) async throws
        -> AgentTabRemoteStart.Started)?

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
        // The folder trust question of this machine (cx-1bhjj), on the tab as its store lists it.
        let ask: RemoteAcpmuxWire.Trust = { [existing, surface, endpoint, reconnect, ownerLink] (cwd: String, level: String?, home: Bool) async throws -> Data in
            let client = AgentSessionAttachClient(surface: try await existing?()?.surface ?? surface, reconnect: reconnect, endpoint: endpoint)
            let answer: Result<Data, any Error>
            do { answer = .success(try await AgentTabRemoteClient(client: client, mode: .attach).mapped { try await client.trust(cwd: cwd, level: level, homeConfirmed: home, ownerLink: ownerLink) }) } catch { answer = .failure(error) }
            await client.close()
            return try answer.get()
        }
        if let session {
            route = AgentPaneRemoteRoute(machine: machine, hostID: hostID, approvals: approvals) { [surface, session, endpoint, reconnect] in
                let client = AgentSessionAttachClient(surface: surface, mode: mode, reconnect: reconnect, endpoint: endpoint)
                return RemoteAcpmuxWire(client: AgentTabRemoteClient(client: client, mode: mode), session: session, host: hostID, linksAlias: linksHost, trust: mode == .attach && servesTrust ? ask : nil)
            }
        } else if let start, mode == .attach {
            // A new chat: nothing runs on that machine until the page's first send (cx-k21v). The
            // page shows the New Tab page or an empty chat; its `session/new` starts the chat.
            route = AgentPaneRemoteRoute(machine: machine, hostID: hostID, approvals: approvals) { [endpoint, reconnect] in
                RemoteAcpmuxWire(start: { [approvals = approvals, servesKeyedReason] cwd, harness, model in
                    let started: AgentTabRemoteStart.Started
                    do {
                        started = try await Self.keyedStart(cwd, harness, model, approvals: approvals,
                                                            servesKeyedReason: servesKeyedReason, proceed: Self.proceedAlways, start: start)
                    } catch let refusal as AgentRemoteStartRefusal {
                        throw AgentSessionRemoteError(code: refusal.code, message: servesTrust ? refusal.userMessage : refusal.withoutTrust.userMessage, folder: refusal.folder)
                    }
                    let client = AgentSessionAttachClient(surface: started.surface, reconnect: reconnect, endpoint: endpoint)
                    return (AgentTabRemoteClient(client: client, mode: .attach), started.session)
                }, host: hostID, linksAlias: linksHost, trust: servesTrust ? ask : nil)
            }
        } else {
            throw AgentRemoteStartRefusal.startUnsupported(machine: machine)
        }
        var handshake = AgentPaneHandshake.acpmux(.remote(route), sessionId: session)
        // The chat exists on its machine: never a fallback to another one.
        if session != nil { handshake.sessionMustExist = true }
        // The composer's machine chip names the chat's machine, not this Mac (cx-k21v).
        handshake.machineName = machine
        handshake.cloudMachineID = cloudMachineID
        handshake.cloudAccount = cloudAccount
        handshake.cloudCredentialRecoveryAvailable = cloudCredentialRecoveryAvailable
        return handshake
    }

    /// A start with no step to check first (the page's own first send). A named function, not a
    /// default `{}`: an async closure default argument can overrun its context (cx-bsue).
    @Sendable static func proceedAlways() async throws {}

    /// Starts the new chat now, as the page's first send would (`cmux cloud start-session`): the
    /// same keyed start, in `cwd` (nil: the tab's seed folder, then its workspace's) with `harness`.
    /// `proceed` runs before each step that changes that machine (a keyed restart, each start
    /// try): its throw stops the start there, and what it threw is what this throws.
    func startNow(cwd: String?, harness: String, model: String? = nil, proceed: @escaping @Sendable () async throws -> Void) async throws -> AgentTabRemoteStart.Started {
        guard let start else { throw AgentRemoteStartRefusal.startUnsupported(machine: machine) }
        return try await Self.keyedStart(cwd, harness, model, approvals: approvals, servesKeyedReason: servesKeyedReason, proceed: proceed, start: start)
    }

    /// The chat's Allow needs this app's key on that machine's agent daemon (cx-oa6ah): an idle
    /// daemon gets it before the start; a busy one waits for the person's restart click on the
    /// Allow notice. That machine's cmux-tui decides whether a restart loses nothing (cx-0w0jj):
    /// the start asks for this app's key, and its `needs_keyed_start` answer says whether to
    /// restart; after the restart (or without one) the chat starts as it is.
    private static func keyedStart(
        _ cwd: String?, _ harness: String?, _ model: String?, approvals: AgentPaneRemoteApprovals?, servesKeyedReason: Bool,
        proceed: @escaping @Sendable () async throws -> Void,
        start unchecked: @escaping @Sendable (String?, String?, String?, AgentSessionAttachClient.PersonKey?) async throws -> AgentTabRemoteStart.Started
    ) async throws -> AgentTabRemoteStart.Started {
        let start = { @Sendable (cwd: String?, harness: String?, model: String?, key: AgentSessionAttachClient.PersonKey?) in
            try await proceed()
            return try await unchecked(cwd, harness, model, key)
        }
        guard let approvals, let prepare = approvals.prepare else { return try await start(cwd, harness, model, nil) }
        guard servesKeyedReason else {
            // An older cmux-tui: the app's own status check (remove with ``AgentPaneRemoteApprovals/Preparation/checkStatus``).
            try await proceed()
            _ = await prepare(.checkStatus)
            return try await start(cwd, harness, model, nil)
        }
        let key = AgentSessionAttachClient.PersonKey(instance: AcpmuxRemotePersonKeys.shared.instance(machine: approvals.machineID))
        do {
            return try await start(cwd, harness, model, key)
        } catch let refusal as AgentRemoteStartRefusal where refusal.code == AgentSessionAttachError.needsKeyedStart {
            // Another chat's keyed restart bound a new key meanwhile: never restart again over it.
            // (nil: a restart runs or failed; prepare joins it or tries again)
            let current = AcpmuxRemotePersonKeys.shared.instance(machine: approvals.machineID)
            let rebound = current != nil && current != key.instance
            if refusal.keyedRestartSafe == true, !rebound {
                try await proceed()
                _ = await prepare(.daemonSaidSafe)
            }
            return try await start(cwd, harness, model, nil)
        }
    }
}

/// ``AgentSessionAttachClient`` as the pane's ``AgentSessionRemoteClient``.
nonisolated struct AgentTabRemoteClient: AgentSessionRemoteClient {
    let client: AgentSessionAttachClient
    let mode: AgentSessionAttachClient.Mode

    var isReadOnly: Bool { mode == .observe }

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

    func permission(id: String, option: String, answers: Data?, annotations: Data?, decisionNonce: String?,
                    personDecision: String?) async throws {
        _ = try await mapped {
            try await client.permission(id: id, option: option, answers: answers, annotations: annotations,
                                        decisionNonce: decisionNonce, personDecision: personDecision)
            return Data()
        }
    }

    func detach() async { await client.detach() }

    func children() async throws -> Data { try await mapped { try await client.children() } }

    func media(path: String) async throws -> Data { try await mapped { try await client.media(path: path) } }

    func typing(_ on: Bool) async throws { _ = try await mapped { try await client.typing(on); return Data() } }

    func view(_ visible: Bool) async throws { _ = try await mapped { try await client.view(visible); return Data() } }

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
        case "agent-session-presence": return .presence(member("presence"))
        default: return .closed(object["reason"] as? String ?? "closed")
        }
    }

    /// The daemon's refusal as the pane's error (its `agent_session.*` code reaches the page).
    func mapped(_ work: () async throws -> Data) async throws -> Data {
        do {
            return try await work()
        } catch let error as AgentSessionAttachError {
            throw AgentSessionRemoteError(code: error.code, message: error.message)
        }
    }
}
