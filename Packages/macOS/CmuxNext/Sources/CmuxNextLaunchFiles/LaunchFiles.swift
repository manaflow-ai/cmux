package import CmuxNextAgentPane
package import CmuxNextHomeEngine
package import CmuxNextTerminal
package import Foundation

/// The saved files this app's launch draws or keeps, besides the daemon's launch snapshot
/// (`DaemonPrestart.launchSnapshot`), each read by its own domain off the main thread from the top
/// of `main` (#17587): the terminals' last frames (`TerminalLaunchFrames`), the agent chats' files
/// (`AgentPaneLaunchReads`) and the Home caches (`HomeLaunchReads`). A pane's last frame is never
/// waited for; a whole value taken while its read still runs is waited for once and marks
/// `launch_read_on_main.<file>` (`scripts/cmux-next/bench-startup.py --launch-guard`).
///
/// Every owner takes its file from here, the one path: the real app process makes it in
/// `CmuxNextApp.main` (`AppEnvironment.startLaunchFiles()`) and hands it over in its environment; a
/// services graph built outside the launch (tests) makes its own from its environment in
/// `AppServices.init`, with no state directory nothing is read. `AppServices.launchFiles` holds it, so
/// the pane builds, the quit's save and the release use one instance of each store.
///
/// ```swift
/// let files = LaunchFiles(state: stateDirectory, chiefHome: home, mark: { DebugTimings.markLaunch($0) })
/// files.prioritize(snapshot.shownTabKeys)  // when the launch snapshot's read ends
/// ```
package nonisolated struct LaunchFiles: Sendable {
    /// The terminals' last frames, decoded by their reader and handed to the pane builds without a wait.
    package let terminalFrames: TerminalLaunchFrames
    /// The agent chats' page images, unsent drafts and composer states.
    package let agent: AgentPaneLaunchReads
    /// The Home conversations' cache and the Home list's last state.
    package let home: HomeLaunchReads

    /// Starts every read now.
    /// - Parameters:
    ///   - state: The build's state directory, where the files are saved (beside its sidebar
    ///     snapshot); nil reads nothing (a services graph built outside the launch).
    ///   - chiefHome: The build's Chief home, whose session names the Home files.
    ///   - mark: Records a launch mark: `launch_read_on_main.<file>` when a take waited on the main
    ///     thread, `terminal.launch_frame_shown` when a terminal's frame decoded after its pane was
    ///     built is shown.
    @MainActor package init(state: URL?, chiefHome: ChiefHome, mark: @escaping @Sendable (String) -> Void) {
        terminalFrames = TerminalLaunchFrames(directory: state.map(TerminalLaunchFrames.directory(beside:)),
                                              onLateFrame: { shown in if shown { mark("terminal.launch_frame_shown") } })
        agent = AgentPaneLaunchReads(state: state, readOnMain: mark)
        home = HomeLaunchReads(owner: chiefHome.session, readOnMain: mark)
    }

    /// Decodes the frames and images of `tabKeys` (the tabs the first windows show, front window
    /// first, from the launch snapshot) before any other.
    package func prioritize(_ tabKeys: [String]) {
        terminalFrames.prioritize(tabKeys)
        agent.pageImages.prioritize(tabKeys)
    }

    /// Drops the decoded frames and images no pane took or asked for (`SavedFrameDirectory.release()`).
    package func release() {
        terminalFrames.release()
        agent.pageImages.release()
    }
}
