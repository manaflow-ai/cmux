public import CmuxNextAgentActivity
import CmuxNextCompat
public import CmuxNextDaemon
public import CmuxNextDaemonService
public import CmuxNextDesign

extension BackdropAgentGlow.Agent {
    /// The agents the backdrop's glow answers (`appearance.agentGlow`): every lane (this Mac's
    /// acpmux and its peers') and every terminal with a live hook agent, as the Chief views count
    /// them, keeping only those that work or wait on the person.
    ///
    /// It reads only what changes when an agent starts or stops working or waiting: the lane
    /// store's ``AgentLaneStore/waitingSessions`` and ``AgentLaneStore/workingSessions``, each
    /// lane's ``AgentLaneStore/links(_:)`` (its machine) and each tab's ``TabModel/agentState``.
    /// An observer of it is not woken by an agent's steps, output or hook times.
    ///
    /// - Parameters:
    ///   - workspaces: every workspace on every machine (`MachineRegistry.allWorkspaces`).
    ///   - machineName: a machine's display name, the name its color is keyed by.
    ///   - localMachine: this Mac's name, the machine of a lane with no peer.
    @MainActor
    public static func current(workspaces: [(WorkspaceModel, DaemonService)], machineName: (DaemonService) -> String?,
                               localMachine: String, lanes: AgentLaneStore = .shared) -> [Self] {
        let lane = { (session: String, level: BackdropAgentGlow.Level) in
            Self(machine: lanes.links(session)?.peer ?? localMachine, level: level)
        }
        var agents = lanes.waitingSessions.map { lane($0, .needsYou) } + lanes.workingSessions.map { lane($0, .working) }
        for (workspace, daemon) in workspaces {
            let machine = machineName(daemon) ?? daemon.machineID
            for tab in workspace.screens.flatMap(\.panes).flatMap(\.tabs) {
                // A chat tab is an acpmux session: its lane above already counts it.
                guard tab.agentSession == nil, !tab.dead, let state = tab.agentState else { continue }
                switch state {
                case .blocked: agents.append(Self(machine: machine, level: .needsYou))
                case .working: agents.append(Self(machine: machine, level: .working))
                case .idle, .done, .unknown: continue
                }
            }
        }
        return agents
    }
}

/// The reader of `appearance.agentGlow` (off by default) that a ``ChiefViewsHost`` holds: it stops
/// when the host is released.
nonisolated final class AgentGlowReader: Sendable {
    let task: Task<Void, Never>

    init(_ task: Task<Void, Never>) { self.task = task }

    deinit { task.cancel() }
}

extension ChiefViewsHost {
    /// This host with the window backdrops' glow (``BackdropAgentGlow``) following its machines, for
    /// as long as the host is kept. Off, the stream reads the switch and nothing else; on, it reads
    /// the agents' states (``BackdropAgentGlow/Agent/current(workspaces:machineName:localMachine:lanes:)``)
    /// and writes ``DesignSettings/agentGlow`` only when the glow changes.
    ///
    /// - Parameter localMachine: this Mac's name (its daemon's), the machine of its own chats.
    @MainActor
    public func followingAgentGlow(localMachine: @escaping @MainActor () -> String?, _ design: DesignSettings = .shared,
                                   theme: ThemeStore = ThemeScope.app.store) -> Self {
        let (workspaces, machineName) = (workspaces, machineName)
        var host = self
        host.agentGlow = AgentGlowReader(Task {
            for await glow in ObservationStream({ () -> BackdropAgentGlow in
                guard design.agentGlowEnabled else { return .calm }
                let agents = BackdropAgentGlow.Agent.current(workspaces: workspaces(), machineName: machineName,
                                                             localMachine: localMachine() ?? "")
                return BackdropAgentGlow(agents: agents) { MachineColor(name: $0).rgb(tokens: theme.tokens, overrides: theme.machineColors) }
            }) where design.agentGlow != glow {
                design.agentGlow = glow
            }
        })
        return host
    }
}
