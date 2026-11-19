import CmuxNextAgentActivity
import CmuxNextCompat
public import CmuxNextDaemon
public import CmuxNextDaemonService
public import CmuxNextDesign

extension BackdropAgentGlow.Agent {
    /// The agents the backdrop's glow answers (`appearance.agentGlow`): every lane (this Mac's
    /// acpmux and its peers') and every terminal with a live hook agent, as the Chief views count
    /// them, keeping only those that work or wait on the person. Reads only states and machines,
    /// never titles or output, so an observer of it wakes on a state change alone.
    ///
    /// - Parameters:
    ///   - workspaces: every workspace on every machine (`MachineRegistry.allWorkspaces`).
    ///   - machineName: a machine's display name, the name its color is keyed by.
    @MainActor
    public static func current(workspaces: [(WorkspaceModel, DaemonService)], machineName: (DaemonService) -> String?) -> [Self] {
        // A lane with no peer runs on this Mac: its color is this Mac's, as its terminals' are.
        let local = workspaces.first { $0.1.isLocal }.flatMap { machineName($0.1) } ?? ""
        var agents = AgentLaneStore.shared.lanes.values.compactMap { lane -> Self? in
            let level: BackdropAgentGlow.Level = switch lane.state {
            case .input: .needsYou
            case .working: .working
            case .idle, .failed, .lost: .calm
            }
            return level == .calm ? nil : Self(machine: lane.peer ?? local, level: level)
        }
        for (workspace, daemon) in workspaces {
            let machine = machineName(daemon) ?? daemon.machineID
            for tab in workspace.screens.flatMap(\.panes).flatMap(\.tabs) {
                // A chat tab is an acpmux session: its lane above already counts it.
                guard tab.agentSession == nil, !tab.dead, let status = tab.agent else { continue }
                switch status.state {
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
    /// the agents' states (``BackdropAgentGlow/Agent/current(workspaces:machineName:)``) and writes
    /// ``DesignSettings/agentGlow`` only when the glow changes.
    @MainActor
    public func followingAgentGlow(_ design: DesignSettings = .shared, theme: ThemeStore = ThemeScope.app.store) -> Self {
        let (workspaces, machineName) = (workspaces, machineName)
        var host = self
        host.agentGlow = AgentGlowReader(Task {
            for await glow in ObservationStream({ () -> BackdropAgentGlow in
                guard design.agentGlowEnabled else { return .calm }
                let agents = BackdropAgentGlow.Agent.current(workspaces: workspaces(), machineName: machineName)
                return BackdropAgentGlow(agents: agents) { MachineColor(name: $0).rgb(tokens: theme.tokens, overrides: theme.machineColors) }
            }) where design.agentGlow != glow {
                design.agentGlow = glow
            }
        })
        return host
    }
}
