import AppKit
public import CmuxNextSignposts
import CmuxNextWakeups

/// Waits, in every build, for a terminal session's surface to hold its first frame: the first IOSurface Ghostty
/// handed its layer (``TerminalSurfaceView/presentedFrame``), drawn in the session's theme. A new tab's
/// `create.tab` interval ends there (p09-observability task 030).
///
/// It reads the layer once per display frame of the surface's window, and only while it waits (most new
/// terminals draw in the frame of the key that made them, so it ticks once or twice). The DEBUG
/// `setContents:` hook (``TypingFrameProbe``) is not used: Release builds have no swizzle.
///
/// `shown` runs once, at the first frame; `closed` runs instead when the session closed or went away first.
/// ``cancel()`` runs neither.
@MainActor
public final class TerminalFirstFrameWatch {
    private weak var session: TerminalSession?
    private var shown: (@MainActor () -> Void)?
    private var closed: (@MainActor () -> Void)?
    private lazy var frames = FrameClient(owner: "TerminalFirstFrameWatch", isAnimation: false, scheduler: { [weak self] in
        self?.session.map { FrameScheduler.forView($0.surfaceView) } ?? .app
    }) { [weak self] _ in self?.check() == false }

    /// Starts waiting; `shown` runs now when the surface has a frame already.
    public init(session: TerminalSession, shown: @escaping @MainActor () -> Void, closed: @escaping @MainActor () -> Void) {
        self.session = session
        self.shown = shown
        self.closed = closed
        if !check() { frames.activate() }
    }

    /// Whether it still waits.
    public var isWaiting: Bool { shown != nil }

    /// Stops waiting without running either callback.
    public func cancel() {
        (shown, closed) = (nil, nil)
        frames.deactivate()
    }

    /// Runs a callback when the wait is over; true once over (the frame client then goes idle).
    private func check() -> Bool {
        guard let shown, let closed else { return true }
        // `close()` takes the surface out of the session's view; a live session always has it there.
        guard let session, session.surfaceView.superview != nil else {
            (self.shown, self.closed) = (nil, nil)
            closed()
            return true
        }
        guard session.surfaceView.presentedFrame != nil else { return false }
        (self.shown, self.closed) = (nil, nil)
        shown()
        return true
    }
}

extension TerminalSession {
    /// This terminal's first frame as a new tab's `create.tab` end (``TerminalFirstFrameWatch``); `content` is its
    /// identity in the pane.
    public func createTabFirstFrame(content: ObjectIdentifier) -> CreateTabTimings.FirstFrame {
        .init(content: content) { [weak self] done in
            guard let self else {
                done(.closed)
                return nil
            }
            let watch = TerminalFirstFrameWatch(session: self, shown: { done(.shown) }, closed: { done(.closed) })
            return { watch.cancel() }
        }
    }
}
