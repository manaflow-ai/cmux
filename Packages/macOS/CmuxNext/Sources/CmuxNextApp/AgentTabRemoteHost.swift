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
    /// Present only for a Cloud VM resolved by the native machine registry, with the signed-in person's name a teammate's machine shows.
    var cloudMachineID: String?, personName: String?
    var cloudAccount: [String?]?
    /// The App opens this Cloud chat's hand-off turns (``CloudHandoffTurnOpener``).
    var cloudHandoffs = false
    /// The prompt rows of session `session` with a turn checkpoint (``AgentPaneHandshake/cloudTurnRewind``);
    /// nil unless `cloud.turnCheckpoints` is on for this signed-in Cloud chat.
    var cloudTurnRewind: (@MainActor @Sendable (_ session: String) async -> [String])?
    /// The machine's daemon answers the folder trust question (`agent-session-trust-v1`).
    var servesTrust = false
    /// The machine's daemon says whether a keyed acpmux restart loses nothing
    /// (`agent-session-start-keyed-reason-v1`, cx-0w0jj).
    var servesKeyedReason = false
    /// The machine's daemon relays a chat's own sign-in (`agent-session-login-v1`) and opens its side
    /// chats there (`agent-session-side-v1`): a new chat's page offers Sign in and New side chat.
    var servesLogin = false, servesSide = false
    /// A new chat signs its agent in there before it has a session (`agent-session-login-machine-v1`).
    var servesMachineLogin = false
    /// After Claude Code signs in from a chat, retire the Mac's legacy model connections.
    var claudeSignedIn: (@Sendable () async -> Void)?
    /// A Cloud machine's link owner answer (``CloudMachineLinks/ownerLink``), read at each trust call
    /// and never kept. Nil for a machine that is not a Cloud machine.
    var ownerLink: AgentSessionAttachClient.OwnerLink?
    /// Redelivers a tracked Copilot grant when this chat reattaches to its guest daemon.
    var restoreCloudCredential: (@Sendable (UInt64) async -> Void)?
    /// Brings the machine's daemon to this app's build now and answers whether an update turn ran
    /// (``DaemonUpdatePolicy/updateNow(_:)``); nil where the app cannot. A start that the machine's
    /// older daemon refused (``AgentRemoteStartRefusal/olderDaemonCodes``, which says which) runs it, then tries once
    /// more: a fresh Cloud machine boots its image's cmux-tui, and the automatic update runs in the background, so a
    /// first chat right after it came up would otherwise reach the old daemon (Leo: "whenever i start a chat it should be able to send me to cloud automatically").
    var updateMachine: (@Sendable () async -> Bool)?
    /// The chat runs on the person's own Cloud VM (``RemoteAcpmuxWire/ownerCloud(_:served:)``).
    var ownerCloud: RemoteAcpmuxWire.OwnerCloud?
    /// A new Cloud chat's steps to its first token on the composer send's timeline (``CloudSendTimelines``, cmux#45953):
    /// its first prompt out, its start answered (with the machine's own phases) and its agent's first text.
    var cloudSendMark: (@Sendable (_ step: String, _ phases: [String: Int]?) -> Void)?

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
        let machineSignIn = if cloudMachineID == nil { true } else { await ownerLink?() != nil }
        let route: AgentPaneRemoteRoute
        // The folder trust question of this machine (cx-1bhjj) and a new chat's sign-in there before it
        // has a session (hq#11225), each on the tab as its store lists it.
        let tab: AgentTabRemoteClient.TabSurface = { [existing, surface] in try await existing?()?.surface ?? surface }
        let ask = AgentTabRemoteClient.trust(tab: tab, reconnect: reconnect, endpoint: endpoint, ownerLink: ownerLink)
        let machineLogin = AgentTabRemoteClient.machineLogin(tab: tab, reconnect: reconnect, endpoint: endpoint, ownerLink: ownerLink)
        if let session {
            if mode == .attach { await restoreCloudCredential?(surface) }
            route = AgentPaneRemoteRoute(machine: machine, hostID: hostID, approvals: approvals) { [surface, session, endpoint, reconnect, personName, machineSignIn] in
                let client = AgentSessionAttachClient(surface: surface, mode: mode, reconnect: reconnect, personName: personName, endpoint: endpoint)
                let cloudRepository = AgentSessionAttachClient.forwardingCloudRepository(surface: surface, reconnect: reconnect, endpoint: endpoint)
                return RemoteAcpmuxWire(client: AgentTabRemoteClient(client: client, mode: mode), session: session, host: hostID, linksAlias: linksHost, trust: mode == .attach && servesTrust ? ask : nil, ownerCloud: mode == .attach ? ownerCloud : nil, cloudRepository: cloudRepository,
                                        machineSignIn: machineSignIn, claudeSignedIn: claudeSignedIn)
            }
        } else if let start, mode == .attach {
            // A new chat: nothing runs on that machine until the page's first send (cx-k21v). The
            // page shows the New Tab page or an empty chat; its `session/new` starts the chat.
            route = AgentPaneRemoteRoute(machine: machine, hostID: hostID, approvals: approvals) { [endpoint, reconnect] in
                RemoteAcpmuxWire(start: { [approvals = approvals, servesKeyedReason, updateMachine, cloudSendMark, restartsInStart = cloudMachineID == nil] cwd, harness, model in
                    let started: AgentTabRemoteStart.Started
                    do {
                        started = try await AgentRemoteStartCoordinator(approvals: approvals, servesKeyedReason: servesKeyedReason,
                                                                  updateMachine: updateMachine, restartsInStart: restartsInStart)
                            .keyedStart(cwd, harness, model, proceed: Self.proceedAlways, start: start)
                    } catch let refusal as AgentRemoteStartRefusal {
                        throw AgentSessionRemoteError(code: refusal.code, message: servesTrust ? refusal.userMessage : refusal.withoutTrust.userMessage, folder: refusal.folder, facts: refusal.pageFacts)
                    }
                    cloudSendMark?("start", started.phases)
                    let client = AgentSessionAttachClient(surface: started.surface, reconnect: reconnect, endpoint: endpoint)
                    return (AgentTabRemoteClient(client: client, mode: .attach), started.session, started.surface)
                }, host: hostID, linksAlias: linksHost, trust: servesTrust ? ask : nil, ownerCloud: ownerCloud,
                cloudRepositoryStart: AgentSessionAttachClient.forwardingStartedCloudRepository(reconnect: reconnect, endpoint: endpoint),
                servesLogin: servesLogin, servesSide: servesSide, machineSignIn: machineSignIn,
                machineLogin: servesMachineLogin ? machineLogin : nil, claudeSignedIn: claudeSignedIn, milestone: cloudSendMark.map { mark -> RemoteAcpmuxWire.Milestone in { step in mark(step, nil) } })
            }
        } else {
            throw AgentRemoteStartRefusal.startUnsupported(machine: machine)
        }
        var handshake = AgentPaneHandshake.acpmux(.remote(route), sessionId: session)
        // The chat exists on its machine: never a fallback to another one.
        if session != nil { handshake.sessionMustExist = true }
        // The composer's machine chip names the chat's machine, not this Mac (cx-k21v).
        handshake.machineName = machine
        (handshake.cloudMachineID, handshake.cloudAccount) = (cloudMachineID, cloudAccount)
        handshake.cloudRepositoryAvailable = cloudMachineID != nil
        if cloudHandoffs { handshake.cloudHandoffs = true }
        if cloudMachineID != nil, let session, let rows = cloudTurnRewind { handshake.cloudTurnRewind = await rows(session) }
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
        return try await AgentRemoteStartCoordinator(approvals: approvals, servesKeyedReason: servesKeyedReason, updateMachine: updateMachine, restartsInStart: cloudMachineID == nil)
            .keyedStart(cwd, harness, model, proceed: proceed, start: start)
    }

}
