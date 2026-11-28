public import CmuxNextDesign
import CmuxNextPages

/// Debug Settings of Cloud machines. Release and RC never activate the store, so they keep the
/// defaults.
public nonisolated struct CloudTunables {
    public nonisolated init() {}
    /// A connected Cloud machine whose cmux-tui is older than the app's (or that the app refused)
    /// is updated to the app's own pinned build through the shared `DaemonUpdatePolicy` (which
    /// `agent.updatePeers` also turns off), also while an agent works there: it picks up where it
    /// stopped. One on a newer build is left alone. Off: only Update Machine updates it. Next to
    /// `agent.updatePeers` in Debug Settings.
    public static let updateCloudMachinesAutomatically = Tunable<Bool>.toggle(
        "cloud.updateMachines", PageTunables.section, "Update Cloud machines automatically",
        help: "A Cloud machine whose cmux-tui is older than this app's gets this app's build, also while an agent works there. Terminals and chats keep running.",
        default: true, code: "CloudTunables.updateCloudMachinesAutomatically")

    /// Both toggles of the automatic Cloud machine update: this one and the shared policy's
    /// `agent.updatePeers`. Read before every step.
    public static var updatesCloudMachines: Bool {
        AgentPaneTunables.updatePeersAutomatically.value && updateCloudMachinesAutomatically.value
    }

    /// Wake on intent (hq#21300), off by default; its rules are Rust's (cmux-cloud-handlers `wake_hint`).
    public static let wakeOnIntent = Tunable<Bool>.toggle("cloud.wakeOnIntent", PageTunables.section, "Wake Cloud machines on focus", help: "A paused Cloud machine starts waking when you focus its chat; unused for 30 seconds, it pauses again.", default: true, code: "CloudTunables.wakeOnIntent")

    /// RFD 0144 piece 2: a read never wakes a VM. On, opening a paused machine's chat shows the daemon's copy of it
    /// (`_acpmux/peer_snapshot`) and wakes nothing; the composer's first key and a terminal still wake it. Default off.
    public static let openWithoutWake = Tunable<Bool>.toggle("cloud.openWithoutWake", PageTunables.section, "Open paused chats without waking", help: "Opening a paused Cloud machine's chat shows its last copy and leaves the machine paused; typing or a terminal wakes it.", default: false, code: "CloudTunables.openWithoutWake")
    public static var all: [TunableDescriptor] { [updateCloudMachinesAutomatically.descriptor, wakeOnIntent.descriptor, openWithoutWake.descriptor] }
}
