public import AppKit
public import CmuxNextDesign

/// The terminals' last frames, saved at quit and drawn over each terminal at launch until its live
/// content draws (launch-speed-first: "the first frame is never blank"). A terminal pane is held
/// clear for launch until its first live frame (`LaunchSettle`): about 150 ms on a capture mini
/// with the daemon running, seconds when it starts cold. One JPEG per tab, named with its scale, as
/// the agent pages' last pages are (`AgentPaneLaunchImages`); each is handed out once per launch.
@MainActor
public final class TerminalLaunchFrames {
    /// A larger file is not read.
    static let maximumBytes = 16 * 1024 * 1024
    private static var stores: [URL: TerminalLaunchFrames] = [:]

    let directory: URL?
    private var taken: Set<String> = []
    /// Hears `terminal_frames` when a frame file was read and decoded on the main thread, for the
    /// launch guard of #17587 (`launch_read_on_main.<name>`).
    public static var onLaunchReadOnMain: ((String) -> Void)?

    init(directory: URL?) {
        self.directory = directory
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
        guard let directory else { return }
        // NSImage stays on the main actor; the JPEG encode and the writes run detached.
        var frames: [String: CGImage] = [:]
        for (key, image) in images where Self.isFileSafe(key) && image.size.width > 0 {
            guard let frame = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
            frames["\(key)@\(max(1, min(3, Int((CGFloat(frame.width) / image.size.width).rounded()))))x.jpg"] = frame
        }
        await Task.detached { Self.write(frames, to: directory) }.value
    }

    /// `key`'s saved frame at its point size, the first time it is asked for.
    func take(_ key: String) -> NSImage? {
        guard let directory, Self.isFileSafe(key), taken.insert(key).inserted else { return nil }
        for scale in [2, 1, 3] {
            let url = directory.appending(path: "\(key)@\(scale)x.jpg")
            guard let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, bytes <= Self.maximumBytes,
                  // concurrency-allow: one capped read of a small local image before the terminal's first frame
                  let data = try? Data(contentsOf: url), let rep = NSBitmapImageRep(data: data) else { continue }
            Self.onLaunchReadOnMain?("terminal_frames")
            let image = NSImage(size: NSSize(width: CGFloat(rep.pixelsWide) / CGFloat(scale), height: CGFloat(rep.pixelsHigh) / CGFloat(scale)))
            rep.size = image.size
            image.addRepresentation(rep)
            return image
        }
        return nil
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
    /// over this terminal in `content`, the pane content held for launch; whether it showed one.
    public func showLaunchFrame(_ key: String, beside state: URL?, in content: NSView) -> Bool {
        TerminalLaunchFrames.beside(state).show(key, on: self, in: content)
    }
}
