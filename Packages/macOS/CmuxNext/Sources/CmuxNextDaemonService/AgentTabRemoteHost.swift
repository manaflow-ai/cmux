public import CmuxNextAgentPane
public import CmuxNextDaemon
public import Foundation

/// The pane host of an agent chat tab whose session runs on another machine: the tab's own
/// session daemon (the remote store that lists it, `agent-session-attach-v1`) carries the chat.
/// Each connection of the page gets a fresh daemon attachment (``RemoteAcpmuxWire`` over
/// ``AgentSessionAttachClient``); the page never reaches that machine's acpmux directly.
public nonisolated struct AgentTabRemoteHost: AgentPaneHostProviding {
    public let surface: UInt64
    /// The chat's session; nil for a new chat that ``start`` starts on its machine first.
    public let session: String?
    public let machine: String
    public let hostID: String
    /// The daemon's store host (`registry:<id>`, ``AgentTabStore/registryHost(of:)``), which opening a
    /// remote child checks its lineage under; the wire notes the daemon's links under it too.
    public var linksHost: String?
    public let endpoint: AgentSessionAttachClient.EndpointProvider
    /// Asked when a connection to the machine fails: reconnects a down link and tries once more
    /// (``AgentPaneMachineLink/reconnecting(machine:)``); nil, never.
    public var reconnect: AgentSessionAttachClient.Reconnect?
    /// `.observe` opens the remote session as a read-only viewer with no mutation fallback.
    public var mode: AgentSessionAttachClient.Mode = .attach
    /// Present only for a Cloud VM resolved by the native machine registry.
    public var cloudMachineID: String?
    public var cloudAccount: [String?]?
    public var cloudCredentialRecoveryAvailable = false
    /// The App opens this Cloud chat's hand-off turns (``CloudHandoffTurnOpener``).
    public var cloudHandoffs = false
    /// The machine's daemon answers the folder trust question (`agent-session-trust-v1`).
    public var servesTrust = false
    /// The machine's daemon says whether a keyed acpmux restart loses nothing
    /// (`agent-session-start-keyed-reason-v1`, cx-0w0jj).
    public var servesKeyedReason = false
    /// A Cloud machine's link owner answer (``CloudMachineLinks/ownerLink``), read at each trust call
    /// and never kept. Nil for a machine that is not a Cloud machine.
    public var ownerLink: AgentSessionAttachClient.OwnerLink?
    /// Brings the machine's daemon to this app's build now and answers whether an update turn ran
    /// (``DaemonUpdatePolicy/updateNow(_:)``); nil where the app cannot. A start that the machine's
    /// older daemon refused (``AgentRemoteStartRefusal/olderDaemonCodes``, which says which) runs it, then tries once
    /// more: a fresh Cloud machine boots its image's cmux-tui, and the automatic update runs in the background, so a
    /// first chat right after it came up would otherwise reach the old daemon (Leo: "whenever i start a chat it should be able to send me to cloud automatically").
    public var updateMachine: (@Sendable () async -> Bool)?
    /// The chat runs on the person's own Cloud VM (``RemoteAcpmuxWire/ownerCloud(_:served:)``).
    public var ownerCloud: RemoteAcpmuxWire.OwnerCloud?
    /// Fixed native owner-auth forwarding for this workspace's per-turn snapshots.
    public var cloudTurn: RemoteAcpmuxWire.CloudTurn?
    /// Owner-authenticated enrollment of the existing workspace machine. It may refresh the
    /// guest's startup scope and reconnect; run before resolving a surface or opening an attachment.
    public var prepareCloudTurns: (@Sendable () async throws -> Void)?

    /// One-shot machine-daemon forwarding for page-host actions, including when the page's ACP
    /// transport itself is local to this Mac.
    public func cloudRepository(method: String, params: [String: any Sendable], timeout: Duration?) async throws -> Data {
        let client = AgentSessionAttachClient(surface: surface, reconnect: reconnect, endpoint: endpoint)
        let result: Result<Data, any Error>
        do {
            result = .success(try await client.cloudRepository(method: method, params: params, timeout: timeout))
        } catch {
            result = .failure(error)
        }
        await client.close()
        return try result.get()
    }

    /// The keyed restart of the machine's acpmux (an SSH machine, or a paired server on the ssh
    /// route); nil where the app has no exec channel of its own (cx-0q7o).
    public var approvals: AgentPaneRemoteApprovals?
    /// The tab this app opened on that machine as the store lists it: its surface there, and its
    /// session once its first send started one. Never starts one.
    public var existing: (@Sendable () async throws -> (surface: UInt64, session: String?)?)?
    /// Starts a new chat in the machine's own acpmux (`agent-session-start`, policy `ask`) in the
    /// page's folder with the page's agent (nil: the tab's own) and answers the tab's surface there
    /// and the session (``AgentTabStore/startRemoteChat``). Called only by the page's first send.
    public var start: (@Sendable (_ cwd: String?, _ harness: String?, _ model: String?, _ personKey: AgentSessionAttachClient.PersonKey?) async throws
        -> Started)?

    /// The daemon's surface and resolved acpmux session after starting a chat.
    public struct Started: Sendable, Equatable {
        public let surface: UInt64
        public let session: String
        public init(surface: UInt64, session: String) { self.surface = surface; self.session = session }
    }

    /// Creates a host from the native registry's machine and daemon endpoint.
    public init(surface: UInt64, session: String?, machine: String, hostID: String,
                endpoint: @escaping AgentSessionAttachClient.EndpointProvider,
                reconnect: AgentSessionAttachClient.Reconnect? = nil, servesTrust: Bool = false,
                servesKeyedReason: Bool = false, approvals: AgentPaneRemoteApprovals? = nil) {
        self.surface = surface
        self.session = session
        self.machine = machine
        self.hostID = hostID
        self.endpoint = endpoint
        self.reconnect = reconnect
        self.servesTrust = servesTrust
        self.servesKeyedReason = servesKeyedReason
        self.approvals = approvals
    }

    public func handshake(sessionId: String?) async throws -> AgentPaneHandshake {
        if mode == .attach { try await prepareCloudTurns?() }
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
                let attachment = CloudTurnAttachment(endpoint: endpoint, ownerLink: ownerLink, turn: mode == .attach ? cloudTurn : nil)
                let client = AgentSessionAttachClient(surface: surface, mode: mode, reconnect: reconnect, endpoint: attachment.endpoint)
                let cloudRepository: RemoteAcpmuxWire.CloudRepository = { method, params, timeout in
                    let requestClient = AgentSessionAttachClient(surface: surface, reconnect: reconnect, endpoint: endpoint)
                    let result: Result<Data, any Error>
                    do {
                        result = .success(try await requestClient.cloudRepository(method: method, params: params, timeout: timeout))
                    } catch {
                        result = .failure(error)
                    }
                    await requestClient.close()
                    return try result.get()
                }
                return RemoteAcpmuxWire(client: AgentTabRemoteClient(client: client, mode: mode), session: session, host: hostID, linksAlias: linksHost, trust: mode == .attach && servesTrust ? ask : nil, ownerCloud: mode == .attach ? ownerCloud : nil, cloudTurn: attachment.turn, cloudRepository: cloudRepository)
            }
        } else if let start, mode == .attach {
            // A new chat: nothing runs on that machine until the page's first send (cx-k21v). The
            // page shows the New Tab page or an empty chat; its `session/new` starts the chat.
            route = AgentPaneRemoteRoute(machine: machine, hostID: hostID, approvals: approvals) { [endpoint, reconnect] in
                let attachment = CloudTurnAttachment(endpoint: endpoint, ownerLink: ownerLink, turn: cloudTurn)
                return RemoteAcpmuxWire(start: { [approvals = approvals, servesKeyedReason, updateMachine] cwd, harness, model in
                    let started: Started
                    do {
                        started = try await Self.keyedStart(cwd, harness, model, approvals: approvals,
                                                            servesKeyedReason: servesKeyedReason, updateMachine: updateMachine,
                                                            proceed: Self.proceedAlways, start: start)
                    } catch let refusal as AgentRemoteStartRefusal {
                        throw AgentSessionRemoteError(code: refusal.code, message: servesTrust ? refusal.userMessage : refusal.withoutTrust.userMessage, folder: refusal.folder)
                    }
                    let client = AgentSessionAttachClient(surface: started.surface, reconnect: reconnect, endpoint: attachment.endpoint)
                    return (AgentTabRemoteClient(client: client, mode: .attach), started.session, started.surface)
                }, host: hostID, linksAlias: linksHost, trust: servesTrust ? ask : nil, ownerCloud: ownerCloud, cloudTurn: attachment.turn,
                cloudRepositoryStart: { surface, method, params, timeout in
                    let requestClient = AgentSessionAttachClient(surface: surface, reconnect: reconnect, endpoint: endpoint)
                    let result: Result<Data, any Error>
                    do {
                        result = .success(try await requestClient.cloudRepository(method: method, params: params, timeout: timeout))
                    } catch {
                        result = .failure(error)
                    }
                    await requestClient.close()
                    return try result.get()
                })
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
        handshake.cloudRepositoryAvailable = true
        if cloudHandoffs { handshake.cloudHandoffs = true }
        return handshake
    }

    /// A start with no step to check first (the page's own first send). A named function, not a
    /// default `{}`: an async closure default argument can overrun its context (cx-bsue).
    @Sendable static func proceedAlways() async throws {}

    /// Starts the new chat now, as the page's first send would (`cmux cloud start-session`): the
    /// same keyed start, in `cwd` (nil: the tab's seed folder, then its workspace's) with `harness`.
    /// `proceed` runs before each step that changes that machine (a keyed restart, each start
    /// try): its throw stops the start there, and what it threw is what this throws.
    public func startNow(cwd: String?, harness: String, model: String? = nil, proceed: @escaping @Sendable () async throws -> Void) async throws -> Started {
        guard let start else { throw AgentRemoteStartRefusal.startUnsupported(machine: machine) }
        if let prepareCloudTurns {
            try await proceed()
            try await prepareCloudTurns()
        }
        return try await Self.keyedStart(cwd, harness, model, approvals: approvals, servesKeyedReason: servesKeyedReason,
                                         updateMachine: updateMachine, proceed: proceed, start: start)
    }

    /// The chat's Allow needs this app's key on that machine's agent daemon (cx-oa6ah): an idle
    /// daemon gets it before the start; a busy one waits for the person's restart click on the
    /// Allow notice. That machine's cmux-tui decides whether a restart loses nothing (cx-0w0jj):
    /// the start asks for this app's key, and its `needs_keyed_start` answer says whether to
    /// restart; after the restart (or without one) the chat starts as it is.
    private static func keyedStart(
        _ cwd: String?, _ harness: String?, _ model: String?, approvals: AgentPaneRemoteApprovals?, servesKeyedReason: Bool,
        updateMachine: (@Sendable () async -> Bool)? = nil,
        proceed: @escaping @Sendable () async throws -> Void,
        start unchecked: @escaping @Sendable (String?, String?, String?, AgentSessionAttachClient.PersonKey?) async throws -> Started
    ) async throws -> Started {
        let start = { @Sendable (cwd: String?, harness: String?, model: String?, key: AgentSessionAttachClient.PersonKey?) in
            try await proceed()
            do {
                return try await unchecked(cwd, harness, model, key)
            } catch let refusal as AgentRemoteStartRefusal where AgentRemoteStartRefusal.olderDaemonCodes.contains(refusal.code) {
                // The machine's daemon may be older than this app's: update it now, then once more.
                guard let updateMachine, await updateMachine() else { throw refusal }
                try await proceed()
                return try await unchecked(cwd, harness, model, key)
            }
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
