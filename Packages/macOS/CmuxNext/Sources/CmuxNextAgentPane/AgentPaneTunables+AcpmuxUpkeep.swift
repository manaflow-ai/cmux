public import CmuxNextDesign
import CmuxNextPages

nonisolated extension AgentPaneTunables {
    /// This app's own acpmux daemon is restarted when it stays alive but stops answering
    /// (``AcpmuxUnresponsiveWatch``). Off, the chats keep saying acpmux did not answer in time.
    public static let restartUnresponsiveAcpmux = Tunable<Bool>.toggle(
        "agent.restartUnresponsiveAcpmux", PageTunables.section, "Restart acpmux when it stops answering",
        help: "This app's acpmux is restarted when it is running but has not answered for about 20 seconds. Agents under agent hosts keep running.",
        default: true, code: "AgentPaneTunables.restartUnresponsiveAcpmux")
}
