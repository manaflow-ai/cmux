public import AppKit
public import CmuxNextDesign
public import CmuxNextWakeups
import CmuxNextCompat

/// The terminals' last frames, saved at quit and drawn over each terminal at launch until its live
/// content draws (launch-speed-first: "the first frame is never blank"). A terminal pane is held
/// clear for launch until its first live frame (`LaunchSettle`): about 150 ms on a capture mini
/// with the daemon running, seconds when it starts cold. One JPEG per tab, named with its scale, as
/// the agent pages' last pages are (`AgentPaneLaunchImages`); each is handed out once per launch. The
/// launch reads and decodes every frame off the main thread from its start (``prefetch(on:keep:mark:)``, in
/// the app's `main` before `NSApplication.run`): a pane shows its frame at once when the read has ended
/// (``LaunchRead``: no main-actor hop), never waiting for it; one shown before then stays held clear, as with
/// no frame, and gets its frame when the read ends if it has drawn nothing live by then.
@MainActor
public final class TerminalLaunchFrames {
    /// A larger file is not read.
    nonisolated static let maximumBytes = 16 * 1024 * 1024
    /// The most frames one launch reads (one per terminal on screen at the last quit).
    nonisolated static let maximumFiles = 64
    private static var stores: [URL: TerminalLaunchFrames] = [:]

    let directory: URL?
    /// Reads the saved frames.
    private let reader: LaunchFileReader
    /// Drops the read's frames after ``prefetch(on:keep:mark:)``'s `keep`.
    private let discard: DemandTimer
    /// The launch read of the saved frames, decoded, by tab key (``prefetch(on:keep:mark:)``); nil before it
    /// starts and once its frames are dropped.
    private var read: LaunchRead<[String: Frame]>?
    /// The frames handed out (each once per launch).
    private var taken: Set<String> = []
    /// Panes that asked while the read ran, by tab key: each gets its frame when the read ends.
    private var waiting: [String: Waiter] = [:]
    /// Records a launch mark.
    private var mark: @Sendable (String) -> Void = { _ in }
    /// Whether the read's results were dropped (``prefetch(on:keep:mark:)`` then starts no new read).
    private var readDropped = false

    /// A saved frame, decoded, with its point size and scale.
    private nonisolated struct Frame: Sendable {
        let image: CGImage
        let size: NSSize
        let scale: Int
    }

    /// A pane that asked for its frame before the read ended.
    private struct Waiter {
        weak var session: TerminalSession?
        weak var content: NSView?
        let reveal: LaunchReveal
    }

    init(directory: URL?, reader: LaunchFileReader = LaunchFileReader(), clock: any Clock<Duration> = ContinuousClock()) {
        self.directory = directory
        self.reader = reader
        discard = DemandTimer(owner: "terminal.launch-frames.keep", clock: clock)
    }

    /// The frames kept in `state`, the app's state directory (beside its sidebar snapshot); one
    /// store per directory, so a frame taken at launch is not handed out again.
    public static func beside(_ state: URL?) -> TerminalLaunchFrames {
        guard let state else { return TerminalLaunchFrames(directory: nil) }
        if let store = stores[state] { return store }
        let store = TerminalLaunchFrames(directory: state.appending(path: "terminal-launch-frames", directoryHint: .isDirectory))
        stores[state] = store
        return store
    }

    /// Starts reading and decoding every saved frame on `work`'s files lane at once; a later call does nothing.
    ///
    /// - Parameters:
    ///   - work: The app's blocking-work lanes.
    ///   - keep: How long the frames no pane took stay in memory (decoded frames are large), from now.
    ///   - mark: Records the launch marks `terminal.launch_frames_read` (on the lane, when the frames are
    ///     decoded: a pane asking after that gets its frame), `terminal.launch_frame_missed` (a pane asked
    ///     before that) and `terminal.launch_frame_shown` (such a pane got its frame when the read ended).
    /// - Returns: A task that ends once the read has ended and the panes that asked before have their frames
    ///   (tests await it).
    @discardableResult
    public func prefetch(on work: BackgroundWork, keep: Duration = .seconds(30),
                         mark: @escaping @Sendable (String) -> Void = { _ in }) -> Task<Void, Never>? {
        guard let directory, read == nil, !readDropped else { return nil }
        self.mark = mark
        let reader = reader
        let read = LaunchRead(on: work) {
            let frames = Self.readAll(in: directory, reader)
            mark("terminal.launch_frames_read")
            return frames
        }
        self.read = read
        // A deadline: the frames no pane took by then are dropped (decoded frames are large).
        discard.schedule(after: keep) { @MainActor [weak self] in self?.dropRead() }
        // task-owner: shows the frames of the panes that asked before the read ended; ends then.
        return Task { [weak self] in
            _ = await read.finished()
            self?.showWaiting()
        }
    }

    /// Drops the read's results that no pane took.
    private func dropRead() {
        read = nil
        readDropped = true
    }

    /// The panes that asked before the read ended get their frames, if they still show the terminal
    /// and it has drawn nothing live.
    private func showWaiting() {
        let waiters = waiting
        waiting = [:]
        for (key, waiter) in waiters {
            guard let session = waiter.session, let content = waiter.content, session.view.isDescendant(of: content),
                  show(key, on: session, in: content, reveal: waiter.reveal) else { continue }
            mark("terminal.launch_frame_shown")
        }
    }

    /// Shows `key`'s frame from the last quit over `session` until its live content draws
    /// (``TerminalLaunchFrame``), and `content`, the pane content held for launch, at once with it
    /// (no fade: it is the frame the pane showed). Never waits: before the launch read ends it shows
    /// nothing (`content` stays held, as with no frame) and shows the frame when the read ends, if the
    /// terminal is still in `content` and has drawn nothing live. Only a frame of the terminal's size and
    /// the window's scale: another would move or scale when the live frame replaced it. Returns whether
    /// it showed one now.
    @discardableResult
    public func show(_ key: String, on session: TerminalSession, in content: NSView, reveal: LaunchReveal = .shared) -> Bool {
        guard let read else { return false }
        guard let frames = read.value else {
            mark("terminal.launch_frame_missed")
            waiting[key] = Waiter(session: session, content: content, reveal: reveal)
            return false
        }
        guard let frame = frames[key], taken.insert(key).inserted else { return false }
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
              content.window.map({ abs(CGFloat(frame.scale) - $0.backingScaleFactor) < 0.01 }) ?? true,
              TerminalLaunchFrame(frame.image).show(on: session) else { return false }
        reveal.release(content)
        session.launchMark?(.savedFrame)
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
        guard let directory else { return }
        // NSImage stays on the main actor; the JPEG encode and the writes run detached.
        var frames: [String: CGImage] = [:]
        for (key, image) in images where Self.isFileSafe(key) && image.size.width > 0 {
            guard let frame = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
            frames["\(key)@\(max(1, min(3, Int((CGFloat(frame.width) / image.size.width).rounded()))))x.jpg"] = frame
        }
        await Task.detached { Self.write(frames, to: directory) }.value
    }

    /// Every saved frame in `directory`, decoded, with its point size and scale, by tab key (for each
    /// key the first scale a save may have written).
    private nonisolated static func readAll(in directory: URL, _ reader: LaunchFileReader) -> [String: Frame] {
        let names = Set(((try? FileManager.checked.contentsOfDirectory(atPath: directory.path)) ?? []).sorted().prefix(maximumFiles))
        var frames: [String: Frame] = [:]
        for scale in [2, 1, 3] {
            let suffix = "@\(scale)x.jpg"
            for name in names where name.hasSuffix(suffix) {
                let key = String(name.dropLast(suffix.count))
                guard frames[key] == nil, isFileSafe(key),
                      let frame = reader.image(at: directory.appending(path: name), maximumBytes: maximumBytes) else { continue }
                frames[key] = Frame(image: frame, size: NSSize(width: CGFloat(frame.width) / CGFloat(scale), height: CGFloat(frame.height) / CGFloat(scale)), scale: scale)
            }
        }
        return frames
    }

    private nonisolated static func write(_ frames: [String: CGImage], to directory: URL) {
        let manager = FileManager.default
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for old in (try? manager.contentsOfDirectory(atPath: directory.path)) ?? [] where frames[old] == nil {
            try? manager.removeItem(at: directory.appending(path: old))
        }
        for (name, frame) in frames {
            let url = directory.appending(path: name)
            guard let data = NSBitmapImageRep(cgImage: frame).representation(using: .jpeg, properties: [.compressionFactor: 0.9]),
                  (try? data.write(to: url, options: [.atomic])) != nil else { continue }
            try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    /// Tab keys are `tab_<hex>`; anything else never becomes a path.
    private nonisolated static func isFileSafe(_ key: String) -> Bool {
        !key.isEmpty && key.count <= 128 && key.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }
}

extension TerminalSession {
    /// Shows `key`'s frame from the last quit, kept in `state` (``TerminalLaunchFrames/beside(_:)``),
    /// over this terminal in `content`, the pane content held for launch; whether it showed one now.
    public func showLaunchFrame(_ key: String, beside state: URL?, in content: NSView) -> Bool {
        TerminalLaunchFrames.beside(state).show(key, on: self, in: content)
    }
}
