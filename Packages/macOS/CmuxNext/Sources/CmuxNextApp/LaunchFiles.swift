import CmuxNextAgentPane
import CmuxNextHomeEngine
import CmuxNextTerminal
import Foundation

/// The saved files this app's launch draws or keeps, besides the daemon's launch snapshot
/// (`DaemonPrestart.launchSnapshot`), each read by its own domain off the main thread from the top
/// of `main` (#17587): the terminals' last frames (`TerminalLaunchFrames`), the agent chats' files
/// (`AgentPaneLaunchReads`) and the Home caches (`HomeLaunchReads`). A pane's last frame is never
/// waited for; a whole value taken while its read still runs is waited for once and marks
/// `launch_read_on_main.<file>` (`scripts/cmux-next/bench-startup.py --launch-guard`).
///
/// Only the real app process makes one (`CmuxNextApp.main`); tests that build `AppServices` have
/// none, and each owner then reads its own file as before.
nonisolated struct LaunchFiles: Sendable {
    let terminalFrames: TerminalLaunchFrames
    let agent: AgentPaneLaunchReads
    let home: HomeLaunchReads

    /// Starts every read now: `state` is the build's state directory, `chiefHome` the build's Chief home.
    @MainActor init(state: URL, chiefHome: ChiefHome) {
        let mark: @Sendable (String) -> Void = { DebugTimings.markLaunch($0) }
        terminalFrames = TerminalLaunchFrames.beside(state)
        terminalFrames.onLateFrameShown = { DebugTimings.markLaunch("terminal.launch_frame_shown") }
        agent = AgentPaneLaunchReads(state: state, readOnMain: mark)
        home = HomeLaunchReads(owner: chiefHome.session, readOnMain: mark)
    }

    /// Decodes the frames and images of `tabKeys` (the tabs the first windows show, front window
    /// first, from the launch snapshot) before any other.
    func prioritize(_ tabKeys: [String]) {
        terminalFrames.prioritize(tabKeys)
        agent.pageImages.prioritize(tabKeys)
    }

    /// Drops the decoded frames and images no pane took: the saved windows are restored and every
    /// pane they show presented its selection (`ContentPresentationScheduler.whenIdle`).
    func release() {
        terminalFrames.release()
        agent.pageImages.release()
    }
}
