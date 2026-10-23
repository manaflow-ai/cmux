public import AppKit
public import CmuxNextDesign

/// The terminals' last frames, saved at quit and drawn over each terminal at launch until its live
/// content draws (launch-speed-first: "the first frame is never blank"). A terminal pane is held
/// clear for launch until its first live frame (`LaunchSettle`): about 150 ms on a capture mini
/// with the daemon running, seconds when it starts cold. One JPEG per tab, named with its scale, as
/// the agent pages' last pages are (`AgentPaneLaunchImages`); each is handed out once per launch.
/// The files are read and decoded off the main thread from the top of `main`
/// (``SavedFrameDirectory``, #17587), so a pane build only takes its decoded frame.
@MainActor
public final class TerminalLaunchFrames {
    /// A larger file is not read.
    public nonisolated static let maximumBytes = 16 * 1024 * 1024

    private let frames: SavedFrameDirectory

    /// The frames of `frames`, the directory the launch began reading in `main`.
    public init(frames: SavedFrameDirectory) {
        self.frames = frames
    }

    /// The frames in `directory` (read from now on); nil keeps none. Tests and the app's no-launch
    /// fallback only: its reads report to no launch guard. The launch reads through ``init(frames:)``.
    package convenience init(directory: URL?) {
        self.init(frames: SavedFrameDirectory(url: directory, maximumBytes: Self.maximumBytes, name: "terminal_frames", readOnMain: { _ in }))
    }

    /// The frames' directory in `state`, the app's state directory (beside its sidebar snapshot).
    public nonisolated static func directory(beside state: URL) -> URL {
        state.appending(path: "terminal-launch-frames", directoryHint: .isDirectory)
    }

    /// Shows `key`'s frame from the last quit over `session` until its live content draws
    /// (``TerminalLaunchFrame``), and `content`, the pane content held for launch, at once with it
    /// (no fade: it is the frame the pane showed). Only a frame of the terminal's size and the
    /// window's scale: another would move or scale when the live frame replaced it. Returns
    /// whether it showed one.
    @discardableResult
    public func show(_ key: String, on session: TerminalSession, in content: NSView, reveal: LaunchReveal = .shared) -> Bool {
        guard let image = take(key) else { return false }
        // The surface's size in this pane: its own frame is a placeholder until the pane lays it out
        // (this transaction does anyway). A pane not laid out yet (zero) takes the launch snapshot's
        // size, which the frame was saved at.
        let laidOut = content.bounds.size != .zero
        if laidOut {
            session.view.frame = content.bounds
            session.view.layoutSubtreeIfNeeded()
        }
        let size = session.surfaceView.bounds.size
        guard !laidOut || (abs(image.size.width - size.width) < 1 && abs(image.size.height - size.height) < 1),
              let frame = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              // The held frame draws at the window's scale: one saved on a screen of another scale would not fit.
              content.window.map({ abs(CGFloat(frame.width) / image.size.width - $0.backingScaleFactor) < 0.01 }) ?? true,
              TerminalLaunchFrame(frame).show(on: session) else { return false }
        reveal.release(content)
        return true
    }

    /// Saves the frames of `sessions` on screen, by tab key, replacing the last quit's. A bare
    /// prompt too: it is what the pane showed.
    public func save(_ sessions: [String: TerminalSession]) async {
        var frames: [String: NSImage] = [:]
        for (key, session) in sessions where !session.isRenderingSuspended {
            let surface = session.surfaceView
            guard surface.window?.isVisible == true, !surface.isHiddenOrHasHiddenAncestor, surface.bounds.width > 0,
                  let frame = await session.snapshotInBackground(maxPixelSize: .greatestFiniteMagnitude) else { continue }
            frames[key] = NSImage(cgImage: frame, size: surface.bounds.size)
        }
        await save(images: frames)
    }

    /// Replaces the saved frames with `images` (by tab key, at their point size).
    func save(images: [String: NSImage]) async {
        guard let directory = self.frames.url else { return }
        // NSImage stays on the main actor; the JPEG encode and the writes run detached.
        var frames: [String: CGImage] = [:]
        for (key, image) in images where SavedFrameDirectory.isFileSafe(key) && image.size.width > 0 {
            guard let frame = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
            let scale = max(1, min(3, Int((CGFloat(frame.width) / image.size.width).rounded())))
            frames[SavedFrameDirectory.fileName(key, scale: scale, ext: "jpg")] = frame
        }
        await Task.detached {
            SavedFrameDirectory.write(frames.compactMapValues {
                NSBitmapImageRep(cgImage: $0).representation(using: .jpeg, properties: [.compressionFactor: 0.9])
            }, to: directory)
        }.value
    }

    /// `key`'s saved frame at its point size, the first time it is asked for.
    func take(_ key: String) -> NSImage? {
        frames.take(key)?.makeImage()
    }
}
