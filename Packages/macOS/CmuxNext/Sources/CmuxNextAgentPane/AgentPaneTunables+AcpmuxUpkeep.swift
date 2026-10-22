public import CmuxNextDesign
import CmuxNextPages

nonisolated extension AgentPaneTunables {
    /// After an update, this app's acpmux daemon of another build is handed off to the bundled
    /// one at once, busy or not, and the new daemon resumes what it interrupted
    /// (``AcpmuxVersionHandoff``). On, the handoff waits for a quiet moment instead: when none of
    /// its sessions runs a turn or waits on a permission (``AcpmuxQuietHandoff``). Off by
    /// default: the team's daemons are hardly ever quiet, so the wait kept old builds running.
    public static let replaceStaleAcpmuxWhenQuiet = Tunable<Bool>.toggle(
        "agent.replaceStaleAcpmuxWhenQuiet", PageTunables.section, "Update acpmux only when its chats are idle",
        help: "Off, an acpmux of an older build is replaced by this app's at once and resumes what it interrupted. On, it waits until no chat is running a turn or waiting on you.",
        default: false, code: "AgentPaneTunables.replaceStaleAcpmuxWhenQuiet")

    /// This app's own acpmux daemon is restarted when it stays alive but stops answering
    /// (``AcpmuxUnresponsiveWatch``). Off, the chats keep saying acpmux did not answer in time.
    public static let restartUnresponsiveAcpmux = Tunable<Bool>.toggle(
        "agent.restartUnresponsiveAcpmux", PageTunables.section, "Restart acpmux when it stops answering",
        help: "This app's acpmux is restarted when it is running but has not answered for about 20 seconds. Agents under agent hosts keep running.",
        default: true, code: "AgentPaneTunables.restartUnresponsiveAcpmux")
}
