public import CmuxNextDesign
import CmuxNextPages

nonisolated extension AgentPaneTunables {
    /// After an update, this app's acpmux daemon of another build is handed off to the bundled
    /// one at a quiet moment: when none of its sessions runs a turn or waits on a permission
    /// (``AcpmuxVersionHandoff``, ``AcpmuxQuietHandoff``). One without agent hosts (an older
    /// build) is replaced too; its chats resume from disk at their next prompt. Off, as before:
    /// one with agent hosts is handed off at once, one without keeps running.
    public static let replaceStaleAcpmuxWhenQuiet = Tunable<Bool>.toggle(
        "agent.replaceStaleAcpmuxWhenQuiet", PageTunables.section, "Update acpmux when its chats are idle",
        help: "An acpmux of an older build is replaced by this app's once no chat is running a turn or waiting on you, also one that would end its agents on a restart.",
        default: true, code: "AgentPaneTunables.replaceStaleAcpmuxWhenQuiet")

    /// This app's own acpmux daemon is restarted when it stays alive but stops answering
    /// (``AcpmuxUnresponsiveWatch``). Off, the chats keep saying acpmux did not answer in time.
    public static let restartUnresponsiveAcpmux = Tunable<Bool>.toggle(
        "agent.restartUnresponsiveAcpmux", PageTunables.section, "Restart acpmux when it stops answering",
        help: "This app's acpmux is restarted when it is running but has not answered for about 20 seconds. Agents under agent hosts keep running.",
        default: true, code: "AgentPaneTunables.restartUnresponsiveAcpmux")
}
