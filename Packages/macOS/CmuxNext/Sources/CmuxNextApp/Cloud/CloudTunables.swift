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

    /// How a window shows a kept Cloud workspace that is not connected (signed out, Cloud off, its machine paused
    /// or not loaded; P-AUSTIN B7). Off: a card with its name, its machine, why and the button. On: one line and
    /// the button. Two variants while Lawrence picks one.
    static let absentCompact = Tunable<Bool>.toggle(
        "cloud.absentCompact", PageTunables.section, "Show a disconnected Cloud workspace in one line",
        help: "Off: a card names the workspace and its machine and says why it is not connected. On: only why, in one line, and the button.",
        default: false, code: "CloudTunables.absentCompact")

    static var all: [TunableDescriptor] { [updateCloudMachinesAutomatically.descriptor, absentCompact.descriptor] }
}
