public import AppKit
public import CmuxNextDesign
import CmuxNextLaunch

/// The terminals' last frames, saved at quit and drawn over each terminal at launch until its live
/// content draws (launch-speed-first: "the first frame is never blank"). A terminal pane is held
/// clear for launch until its first live frame (`LaunchSettle`): about 150 ms on a capture mini
/// with the daemon running, seconds when it starts cold. One JPEG per tab, named with its scale, as
/// the agent pages' last pages are (`AgentPaneLaunchImages`); each is handed out once per launch.
///
/// The files are listed and decoded off the main thread by a ``SavedFrameDirectory`` started at
/// the top of `main` (the app's `LaunchFiles` makes the launch's store there, #17587), so a pane
/// build only takes a decoded frame; one not decoded yet is drawn when it is, unless the terminal's
/// live content drew first. Nothing here reads a file or waits on the main thread.
@MainActor
public final class TerminalLaunchFrames {
    /// A larger file is not read.
    public nonisolated static let maximumBytes = 16 * 1024 * 1024
    /// One store per state directory, so a frame taken at launch is not handed out again and the
    /// launch's store (made in `main`) is the one the pane builds and the quit use.
    private static var stores: [URL: TerminalLaunchFrames] = [:]

    private let frames: SavedFrameDirectory
    /// Hears each frame shown after its pane was built (the decode came later than the pane), for
    /// the launch marks; the app sets it.
    public var onLateFrameShown: (() -> Void)?

    /// The frames of `frames` (tests pass a directory whose decodes they hold).
    init(frames: SavedFrameDirectory) {
        self.frames = frames
    }

    /// The frames in `directory`, listed and decoded from now on; nil keeps none.
    convenience init(directory: URL?) {
        self.init(frames: SavedFrameDirectory(url: directory, maximumBytes: Self.maximumBytes, name: "terminal_frames"))
    }

    /// The frames' directory in `state`, the app's state directory (beside its sidebar snapshot).
    public nonisolated static func directory(beside state: URL) -> URL {
        state.appending(path: "terminal-launch-frames", directoryHint: .isDirectory)
    }

    /// The frames kept in `state`, the app's state directory (beside its sidebar snapshot); one
    /// store per directory. The first call starts reading the frames: `main` makes the launch's.
    public static func beside(_ state: URL?) -> TerminalLaunchFrames {
        guard let state else { return TerminalLaunchFrames(directory: nil) }
        if let store = stores[state] { return store }
        let store = TerminalLaunchFrames(directory: directory(beside: state))
        stores[state] = store
        return store
    }

    /// Decodes the frames of `keys` (the tabs the first windows show, front window first) first.
    /// From any thread: the launch calls it when the launch snapshot's read ends.
    public nonisolated func prioritize(_ keys: [String]) {
        frames.prioritize(keys)
    }

    /// Returns once every frame is decoded (tests).
    func decoded() async {
        await frames.readerIdle()
    }

    /// Drops the decoded frames no pane took: a terminal shown later draws its live content only.
    public nonisolated func release() {
        frames.release()
    }

    /// Shows `key`'s frame from the last quit over `session` until its live content draws
    /// (``TerminalLaunchFrame``), and `content`, the pane content held for launch, at once with it
    /// (no fade: it is the frame the pane showed). Only a frame of the terminal's size and the
    /// window's scale: another would move or scale when the live frame replaced it. A frame not
    /// decoded yet is shown when it is, unless the terminal drew its own content first. Returns
    /// whether it showed one now.
    @discardableResult
    public func show(_ key: String, on session: TerminalSession, in content: NSView, reveal: LaunchReveal = .shared) -> Bool {
        let decoded = frames.take(key) { [weak self, weak session, weak content] frame in
            guard let self, let session, let content, Self.present(frame, on: session, in: content, reveal: reveal) else { return }
            self.onLateFrameShown?()
        }
        guard let decoded else { return false }
        return Self.present(decoded, on: session, in: content, reveal: reveal)
    }

    /// Shows `frame` over `session` in `content` when it fits the terminal and the window's scale.
    private static func present(_ frame: SavedFrame, on session: TerminalSession, in content: NSView, reveal: LaunchReveal) -> Bool {
        // The surface's size in this pane: its own frame is a placeholder until the pane lays it out
        // (this transaction does anyway). A pane not laid out yet (zero) takes the launch snapshot's
        // size, which the frame was saved at.
        let laidOut = content.bounds.size != .zero
        if laidOut {
            session.view.frame = content.bounds
            session.view.layoutSubtreeIfNeeded()
        }
        let size = session.surfaceView.bounds.size
        guard !laidOut || (abs(frame.size.width - size.width) < 1 && abs(frame.size.height - size.height) < 1),
              // The held frame draws at the window's scale: one saved on a screen of another scale would not fit.
              content.window.map({ abs(CGFloat(frame.image.width) / frame.size.width - $0.backingScaleFactor) < 0.01 }) ?? true,
              TerminalLaunchFrame(frame.image).show(on: session) else { return false }
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
}

extension TerminalSession {
    /// Shows `key`'s frame from the last quit, kept in `state` (``TerminalLaunchFrames/beside(_:)``),
    /// over this terminal in `content`, the pane content held for launch; whether it showed one now
    /// (a frame decoded later shows when it is).
    public func showLaunchFrame(_ key: String, beside state: URL?, in content: NSView) -> Bool {
        TerminalLaunchFrames.beside(state).show(key, on: self, in: content)
    }
}
