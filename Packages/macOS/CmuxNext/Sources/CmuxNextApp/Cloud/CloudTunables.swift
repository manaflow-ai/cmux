import CmuxNextAgentPane
import CmuxNextDesign
import CmuxNextPages

/// Debug Settings of Cloud machines. Release and RC never activate the store, so they keep the
/// defaults.
nonisolated struct CloudTunables {
    /// A connected Cloud machine whose cmux-tui is older than the app's (or that the app refused)
    /// is updated to the app's own pinned build through the shared `DaemonUpdatePolicy` (which
    /// `agent.updatePeers` also turns off), also while an agent works there: it picks up where it
    /// stopped. One on a newer build is left alone. Off: only Update Machine updates it. Next to
    /// `agent.updatePeers` in Debug Settings.
    static let updateCloudMachinesAutomatically = Tunable<Bool>.toggle(
        "cloud.updateMachines", PageTunables.section, "Update Cloud machines automatically",
        help: "A Cloud machine whose cmux-tui is older than this app's gets this app's build, also while an agent works there. Terminals and chats keep running.",
        default: true, code: "CloudTunables.updateCloudMachinesAutomatically")

    /// Both toggles of the automatic Cloud machine update: this one and the shared policy's
    /// `agent.updatePeers`. Read before every step.
    static var updatesCloudMachines: Bool {
        AgentPaneTunables.updatePeersAutomatically.value && updateCloudMachinesAutomatically.value
    }

    static var all: [TunableDescriptor] { [updateCloudMachinesAutomatically.descriptor] }
}
