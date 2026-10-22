import CmuxNextAgentPane
import CmuxNextDaemonRecovery
import CmuxNextDesign

/// Debug Settings of Cloud machines. Release and RC never activate the store, so they keep the
/// defaults.
nonisolated struct CloudTunables {
    /// A connected Cloud machine on another cmux-tui build than the app's is updated to the app's
    /// own pinned build, also while an agent works there (``CloudMachineUpdates``, through the
    /// shared `DaemonUpdatePolicy`, which `agent.updatePeers` also turns off). Off: only Update
    /// Machine updates it.
    static let updateCloudMachinesAutomatically = Tunable<Bool>.toggle(
        "cloud.updateMachines", DaemonTunables.section, "Update Cloud machines automatically",
        help: "A Cloud machine on an older cmux-tui gets this app's build, also while an agent works there. Terminals and chats keep running.",
        default: true, code: "CloudTunables.updateCloudMachinesAutomatically")

    /// Both toggles of the automatic Cloud machine update: this one and the shared policy's
    /// `agent.updatePeers`. Read before every step.
    static var updatesCloudMachines: Bool {
        AgentPaneTunables.updatePeersAutomatically.value && updateCloudMachinesAutomatically.value
    }

    static var all: [TunableDescriptor] { [updateCloudMachinesAutomatically.descriptor] }
}
