public import CmuxNextDesign
import CmuxNextPages

nonisolated extension AgentPaneTunables {
    /// After an update, the app brings the daemons of other machines (acpmux ssh peers, Cloud
    /// machines) to its own build (``DaemonUpdatePolicy``), one at a time: at a quiet moment, or
    /// after 10 minutes also while an agent works there, which picks up where it stopped.
    /// Read at launch and before each machine's update, so turning it off stops the rest.
    public static let updatePeersAutomatically = Tunable<Bool>.toggle(
        "agent.updatePeers", PageTunables.section, "Update other machines automatically",
        help: "After cmux updates, ssh and Cloud machines get the same build, one at a time: when idle, or after 10 minutes also while an agent works there, which picks up where it stopped.",
        default: true, code: "AgentPaneTunables.updatePeersAutomatically")
}
