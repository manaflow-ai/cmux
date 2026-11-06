import CmuxFoundation
import Darwin

/// The agent processes a Claude account switch replaces, and the checks that keep one Claude
/// session from running in two places.
///
/// The switch stops the pane's Claude by closing the pane's terminal, which reaches only processes
/// whose controlling terminal is that terminal. A Claude inside tmux or screen, or one detached
/// from any terminal, outlives the switch and keeps writing the session the resumed Claude
/// continues, so the switch refuses it up front (``ownership(paneTTYDevice:)``). A Claude that
/// is still running after the exit wait gets no resume typed (``stillRunning``). Every live owner
/// the agent index names for the session is checked with the pane's recorded processes
/// (``including(liveSessionOwners:)``), and a Claude that started in the pane while the switch
/// awaited is caught by ``startedProcesses(since:)``.
struct ClaudeAccountSwitchReplacedAgents {
    /// Whether the switch can stop the replaced agents by closing the pane's terminal.
    enum Ownership: Equatable {
        /// No recorded agent process is still running; there is nothing to stop.
        case noLiveAgent
        /// Every running agent process has the pane's terminal as its controlling terminal.
        case ownedByPane
        /// A running agent process has another controlling terminal or none, or the pane's own
        /// terminal is unknown, so closing the pane might leave it running.
        case notOwnedByPane
    }

    /// The agent processes recorded for the pane when the switch started.
    let processes: [AgentPIDProcessIdentity]
    private let currentIdentity: (pid_t) -> AgentPIDProcessIdentity?
    private let controllingTTYDevice: (pid_t) -> Int64?

    /// - Parameters:
    ///   - processes: The agent processes recorded for the pane.
    ///   - currentIdentity: Reads a pid's current process generation, `nil` once it is gone. A
    ///     different generation means the pid was reused and the recorded process is gone.
    ///   - controllingTTYDevice: Reads a running pid's controlling terminal device, `nil` when it
    ///     has none or cannot be read.
    init(
        processes: [AgentPIDProcessIdentity],
        currentIdentity: @escaping (pid_t) -> AgentPIDProcessIdentity? = { AgentPIDProcessIdentity(pid: $0) },
        controllingTTYDevice: @escaping (pid_t) -> Int64? = { agentLiveProcessIdentity(pid: $0)?.ttyDevice }
    ) {
        self.processes = processes
        self.currentIdentity = currentIdentity
        self.controllingTTYDevice = controllingTTYDevice
    }

    /// The recorded processes still running as the same process generation.
    var stillRunning: [AgentPIDProcessIdentity] {
        processes.filter { currentIdentity($0.pid) == $0 }
    }

    /// These agents plus every process the agent index names as a live owner of the session that
    /// they don't already name. A Claude whose pid never reached the pane's record (hooks that
    /// never reported it, or a record lost with a relaunch) is then checked like a recorded one
    /// instead of passing as "nothing to stop", and so is a second Claude running the same session
    /// in another terminal while the pane's own one runs: restarting the pane stops only the latter.
    func including(liveSessionOwners owners: [AgentPIDProcessIdentity]) -> Self {
        var processes = processes
        for owner in owners where !processes.contains(owner) {
            processes.append(owner)
        }
        return Self(processes: processes, currentIdentity: currentIdentity, controllingTTYDevice: controllingTTYDevice)
    }

    /// The processes running now that `earlier` did not name: a Claude that started in the pane
    /// since `earlier` was read. A reused pid is a new process generation, so it counts as new.
    func startedProcesses(since earlier: Self) -> [AgentPIDProcessIdentity] {
        let known = Set(earlier.processes)
        return stillRunning.filter { !known.contains($0) }
    }

    /// Whether closing the pane's terminal, whose PTY device is `paneTTYDevice`, stops every
    /// recorded process that is still running. An unknown pane terminal or an unreadable process
    /// terminal counts as not owned: the switch fails closed rather than risk a second writer.
    func ownership(paneTTYDevice: Int64?) -> Ownership {
        let running = stillRunning
        guard !running.isEmpty else { return .noLiveAgent }
        guard let paneTTYDevice else { return .notOwnedByPane }
        return running.allSatisfy { controllingTTYDevice($0.pid) == paneTTYDevice } ? .ownedByPane : .notOwnedByPane
    }
}
