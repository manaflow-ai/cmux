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
/// Every owner takes its file from here, the one path: the real app process makes it in
/// `CmuxNextApp.main` (``init(environment:)``) and hands it over in its environment; a services graph
/// built outside the launch (tests) makes its own from its environment in `AppServices.init`, with no
/// state directory nothing is read. `AppServices.launchFiles` holds it, so the pane builds, the quit's
/// save and the release use one instance of each store.
nonisolated struct LaunchFiles: Sendable {
    let terminalFrames: TerminalLaunchFrames
    let agent: AgentPaneLaunchReads
    let home: HomeLaunchReads

    /// Starts every read now: `state` is the build's state directory (nil: no state files, a
    /// services graph built outside the launch), `chiefHome` the build's Chief home.
    @MainActor init(state: URL?, chiefHome: ChiefHome) {
        let mark: @Sendable (String) -> Void = { DebugTimings.markLaunch($0) }
        terminalFrames = TerminalLaunchFrames(directory: state.map(TerminalLaunchFrames.directory(beside:)))
        terminalFrames.onLateFrameShown = { DebugTimings.markLaunch("terminal.launch_frame_shown") }
        agent = AgentPaneLaunchReads(state: state, readOnMain: mark)
        home = HomeLaunchReads(owner: chiefHome.session, readOnMain: mark)
    }

    /// The launch files of `environment`: its state directory (beside its sidebar snapshot) and its
    /// tag's Chief home.
    @MainActor init(environment: AppEnvironment) {
        self.init(state: environment.sidebarSnapshotFile?.url.deletingLastPathComponent(),
                  chiefHome: ChiefHome.resolve(tag: environment.tag))
    }

    /// Decodes the frames and images of `tabKeys` (the tabs the first windows show, front window
    /// first, from the launch snapshot) before any other.
    func prioritize(_ tabKeys: [String]) {
        terminalFrames.prioritize(tabKeys)
        agent.pageImages.prioritize(tabKeys)
    }

    /// Drops the decoded frames and images no pane took or asked for (``SavedFrameDirectory/release()``).
    func release() {
        terminalFrames.release()
        agent.pageImages.release()
    }
}
