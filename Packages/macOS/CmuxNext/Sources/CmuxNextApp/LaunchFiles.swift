import CmuxNextAgentPane
import CmuxNextLaunch
import CmuxNextTerminal
import Foundation

/// The saved files this app reads before its first window frame, besides the daemon's launch
/// snapshot (`DaemonPrestart.launchSnapshot`): the saved sidebars, the terminals' last frames, the
/// agent pages' last images and the new chats' unsent drafts (read when the agent tab store is made
/// in `applicationDidFinishLaunching`). `main` starts reading and decoding all of them on background
/// threads before AppKit starts, so none is read on the main thread while the first window is built
/// (#17587: the sidebar's JSON decode alone held the main thread for up to 100 ms, and each shown
/// pane decoded its JPEG there). A read that has not finished when the app takes it is waited for
/// (the rest of it), never read twice, and marks `launch_read_on_main.<file>`
/// (`scripts/cmux-next/bench-startup.py --launch-guard`).
nonisolated struct LaunchFiles: Sendable {
    /// The saved sidebars' store, made (its file read and decoded) off the main thread.
    let sidebar: LaunchRead<SidebarSnapshotStore>
    /// The terminals' last frames (`TerminalLaunchFrames`).
    let terminalFrames: SavedFrameDirectory
    /// The agent pages' last images (`AgentPaneLaunchImages`).
    let agentPageImages: SavedFrameDirectory
    /// The new chats' unsent drafts (`AgentUnsentDrafts`), by tab.
    let unsentDrafts: LaunchRead<[String: String]>

    /// Starts every read now. `sidebarFile` names the build's state directory, where the frames
    /// and images are saved beside it.
    init(sidebarFile: SidebarSnapshotFile) {
        let mark: @Sendable (String) -> Void = { DebugTimings.markLaunch($0) }
        let state = sidebarFile.url.deletingLastPathComponent()
        sidebar = LaunchRead("sidebar_snapshot", readOnMain: mark) { SidebarSnapshotStore(file: sidebarFile) }
        terminalFrames = SavedFrameDirectory(url: TerminalLaunchFrames.directory(beside: state),
                                             maximumBytes: TerminalLaunchFrames.maximumBytes,
                                             name: "terminal_frames", readOnMain: mark)
        agentPageImages = SavedFrameDirectory(url: AgentPaneLaunchImages.directory(beside: state),
                                              maximumBytes: AgentPaneLaunchImages.maximumBytes,
                                              name: "agent_page_images", readOnMain: mark)
        let draftsFile = AgentUnsentDrafts.file(in: state)
        unsentDrafts = LaunchRead("unsent_drafts", readOnMain: mark) { AgentUnsentDrafts.read(draftsFile) }
    }

    /// Decodes the frames and images of `tabKeys` (the tabs the first windows show, front window
    /// first, from the launch snapshot) before any other.
    func prioritize(_ tabKeys: [String]) {
        terminalFrames.prioritize(tabKeys)
        agentPageImages.prioritize(tabKeys)
    }

    /// Drops the decoded frames and images no pane took: the saved windows are restored and every
    /// pane they show presented its selection (`ContentPresentationScheduler.whenIdle`).
    func release() {
        terminalFrames.release()
        agentPageImages.release()
    }
}
