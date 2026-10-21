import AppKit
import CmuxNextDesign
import CmuxNextTerminal

/// The terminals' last frames, saved at quit and drawn over each terminal at launch until its live
/// content draws (launch-speed-first: "the first frame is never blank"). A terminal pane is held
/// clear for launch until its first live frame (`LaunchSettle`): about 150 ms on a capture mini
/// with the daemon running, seconds when it starts cold. Stored as the agent pages' are
/// (`AgentPaneLaunchImages`), in a directory of their own; each frame is handed out once per launch.
@MainActor
final class TerminalLaunchFrames {
    static let directoryName = "terminal-launch-frames"
    /// The app's frames, beside the sidebar snapshot (`CmuxNextApp.main`); none until then.
    static var shared = TerminalLaunchFrames(directory: nil)

    private let images: AgentPaneLaunchImages

    init(directory: URL?) {
        images = AgentPaneLaunchImages(directory: directory)
    }

    /// The directory next to the launch snapshot of `file` (the tag's state).
    convenience init(beside file: SidebarSnapshotFile?) {
        self.init(directory: file?.url.deletingLastPathComponent().appending(path: Self.directoryName, directoryHint: .isDirectory))
    }

    /// Shows `key`'s frame from the last quit over `session` until its live content draws, and
    /// `content`, the pane content held for launch, at once with it (no fade: it is the frame the
    /// pane showed). Only a frame of the terminal's size: one of another size would move when the
    /// live frame replaces it. Returns whether it showed one.
    @discardableResult
    func show(_ key: String, on session: TerminalSession, in content: NSView, reveal: LaunchReveal = .shared) -> Bool {
        guard let image = images.take(key) else { return false }
        // Not laid out yet (zero): the pane takes the launch snapshot's size, which the frame was saved at.
        let size = session.surfaceView.bounds.size
        guard size == .zero || (abs(image.size.width - size.width) < 1 && abs(image.size.height - size.height) < 1),
              let frame = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              TerminalLaunchFrame(frame).show(on: session) else { return false }
        reveal.release(content)
        DebugTimings.markLaunch("terminal.launch_frame_shown")
        return true
    }

    /// The frames of `cache`'s terminals on screen that show output, by tab key, at their point
    /// size: saved at quit for the next launch.
    func shownFrames(of cache: TabContentCache) async -> [String: NSImage] {
        var frames: [String: NSImage] = [:]
        for (key, entry) in cache.terminals where !entry.session.isRenderingSuspended && entry.session.showsOutput {
            let surface = entry.session.surfaceView
            guard surface.window?.isVisible == true, !surface.isHiddenOrHasHiddenAncestor, surface.bounds.width > 0,
                  let frame = await entry.session.snapshotInBackground(maxPixelSize: .greatestFiniteMagnitude) else { continue }
            frames[key] = NSImage(cgImage: frame, size: surface.bounds.size)
        }
        return frames
    }

    /// Replaces the saved frames with `frames` (by tab key).
    func save(_ frames: [String: NSImage]) async {
        await images.save(frames)
    }
}
