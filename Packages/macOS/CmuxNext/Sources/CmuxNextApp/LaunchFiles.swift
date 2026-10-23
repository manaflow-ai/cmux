import CmuxNextCompat
import CmuxNextDesign
import CmuxNextTerminal
import Foundation

/// The saved files this app's first window draws before the daemon answers, besides the daemon's
/// launch snapshot (`DaemonPrestart.launchSnapshot`): the saved sidebars, the terminals' last
/// frames and the agent pages' last images. `main` starts reading and decoding all of them on
/// background tasks before AppKit starts, so none is read on the main thread while the first window
/// is built (#17587: the sidebar's JSON decode alone held the main thread for up to 100 ms, and
/// each shown pane decoded its JPEG there). A read that has not finished when the window takes it
/// is read on the main thread, never waited for, and marks `launch_read_on_main.<file>`
/// (`scripts/cmux-next/bench-startup.py --launch-guard`).
nonisolated struct LaunchFiles: Sendable {
    /// The saved sidebars (`SidebarSnapshotStore`); nil when none was saved or it is unreadable.
    let sidebar: LaunchRead<SidebarSnapshotDocument?>
    /// The terminals' last frames (`TerminalLaunchFrames`).
    let terminalFrames: SavedFrameDirectory
    /// The agent pages' last images (`AgentPaneLaunchImages`).
    let agentPageImages: SavedFrameDirectory

    /// Starts every read now. `sidebarFile` names the build's state directory, where the frames
    /// and images are saved beside it.
    init(sidebarFile: SidebarSnapshotFile) {
        let mark: @Sendable (String) -> Void = { DebugTimings.markLaunch($0) }
        let state = sidebarFile.url.deletingLastPathComponent()
        sidebar = LaunchRead("sidebar_snapshot", readOnMain: mark) { sidebarFile.read() }
        terminalFrames = SavedFrameDirectory(url: TerminalLaunchFrames.directory(beside: state),
                                             maximumBytes: TerminalLaunchFrames.maximumBytes,
                                             name: "terminal_frames", readOnMain: mark)
        agentPageImages = SavedFrameDirectory(url: AgentPaneLaunchImages.directory(beside: state),
                                              maximumBytes: AgentPaneLaunchImages.maximumBytes,
                                              name: "agent_page_images", readOnMain: mark)
    }

    /// Drops the decoded frames and images no pane took: the launch settled (`LaunchSettle`).
    func release() {
        terminalFrames.release()
        agentPageImages.release()
    }
}
