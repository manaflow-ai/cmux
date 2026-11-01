import CmuxNextAgentPane
import CmuxNextDaemon
import CmuxNextDaemonService
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
    /// The App opens this Cloud chat's hand-off turns (``CloudHandoffTurnOpener``).
    var cloudHandoffs = false
    /// The machine's daemon answers the folder trust question (`agent-session-trust-v1`).
    var servesTrust = false
    /// The machine's daemon says whether a keyed acpmux restart loses nothing
    /// (`agent-session-start-keyed-reason-v1`, cx-0w0jj).
    var servesKeyedReason = false
    /// The machine's daemon relays a chat's own sign-in (`agent-session-login-v1`): a new chat's
    /// page offers Sign in from its first turn.
    var servesLogin = false
    /// A Cloud machine's link owner answer (``CloudMachineLinks/ownerLink``), read at each trust call
    /// and never kept. Nil for a machine that is not a Cloud machine.
    var ownerLink: AgentSessionAttachClient.OwnerLink?
    /// Brings the machine's daemon to this app's build now and answers whether an update turn ran
    /// (``DaemonUpdatePolicy/updateNow(_:)``); nil where the app cannot. A start that the machine's
    /// older daemon refused (``AgentRemoteStartRefusal/olderDaemonCodes``, which says which) runs it, then tries once
    /// more: a fresh Cloud machine boots its image's cmux-tui, and the automatic update runs in the background, so a
    /// first chat right after it came up would otherwise reach the old daemon (Leo: "whenever i start a chat it should be able to send me to cloud automatically").
    var updateMachine: (@Sendable () async -> Bool)?
    /// The chat runs on the person's own Cloud VM (``RemoteAcpmuxWire/ownerCloud(_:served:)``).
    var ownerCloud: RemoteAcpmuxWire.OwnerCloud?

    func cloudRepository(method: String, params: [String: any Sendable], timeout: Duration?) async throws -> Data {
        try await AgentSessionAttachClient.forwardingCloudRepository(surface: surface, reconnect: reconnect, endpoint: endpoint,
                                                              method: method, params: params, timeout: timeout)
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
                let cloudRepository = AgentSessionAttachClient.forwardingCloudRepository(surface: surface, reconnect: reconnect, endpoint: endpoint)
                return RemoteAcpmuxWire(client: AgentTabRemoteClient(client: client, mode: mode), session: session, host: hostID, linksAlias: linksHost, trust: mode == .attach && servesTrust ? ask : nil, ownerCloud: mode == .attach ? ownerCloud : nil, cloudRepository: cloudRepository)
            }
        } else if let start, mode == .attach {
            // A new chat: nothing runs on that machine until the page's first send (cx-k21v). The
            // page shows the New Tab page or an empty chat; its `session/new` starts the chat.
            route = AgentPaneRemoteRoute(machine: machine, hostID: hostID, approvals: approvals) { [endpoint, reconnect] in
                RemoteAcpmuxWire(start: { [approvals = approvals, servesKeyedReason, updateMachine] cwd, harness, model in
                    let started: AgentTabRemoteStart.Started
                    do {
                        started = try await AgentRemoteStartCoordinator(approvals: approvals, servesKeyedReason: servesKeyedReason,
                                                                  updateMachine: updateMachine)
                            .keyedStart(cwd, harness, model, proceed: Self.proceedAlways, start: start)
                    } catch let refusal as AgentRemoteStartRefusal {
                        throw AgentSessionRemoteError(code: refusal.code, message: servesTrust ? refusal.userMessage : refusal.withoutTrust.userMessage, folder: refusal.folder)
                    }
                    let client = AgentSessionAttachClient(surface: started.surface, reconnect: reconnect, endpoint: endpoint)
                    return (AgentTabRemoteClient(client: client, mode: .attach), started.session, started.surface)
                }, host: hostID, linksAlias: linksHost, trust: servesTrust ? ask : nil, ownerCloud: ownerCloud,
                cloudRepositoryStart: AgentSessionAttachClient.forwardingStartedCloudRepository(reconnect: reconnect, endpoint: endpoint),
                servesLogin: servesLogin)
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
    func startNow(cwd: String?, harness: String, model: String? = nil, proceed: @escaping @Sendable () async throws -> Void) async throws -> AgentTabRemoteStart.Started {
        guard let start else { throw AgentRemoteStartRefusal.startUnsupported(machine: machine) }
        return try await AgentRemoteStartCoordinator(approvals: approvals, servesKeyedReason: servesKeyedReason, updateMachine: updateMachine)
            .keyedStart(cwd, harness, model, proceed: proceed, start: start)
    }

}
