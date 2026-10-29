import AppKit
public import CmuxNextSignposts
public import CmuxNextWakeups

/// Waits, in every build, for a terminal session's surface to hold its first frame: the first IOSurface its renderer
/// presented (``TerminalSurfaceView/presentedFrame``), drawn in the session's theme. A new tab's
/// `create.tab` interval ends there (p09-observability task 030).
///
/// It reads the presented frame once per display frame of the surface's window, and only while it waits (most new
/// terminals draw in the frame of the key that made them, so it ticks once or twice). A tab hidden first cancels
/// it (``CreateTabTimings/hidden(_:)``), so a hidden terminal, whose rendering is suspended, costs no frames. The
/// DEBUG `setContents:` hook (``TypingFrameProbe``) is not used: Release builds have no swizzle.
///
/// `shown` runs once, at the first frame (in the init's call when the frame exists already); `closed` runs
/// instead when the surface closed or went away first. ``cancel()`` runs neither.
@MainActor
public final class TerminalFirstFrameWatch {
    /// What the watch reads of the surface each frame.
    public enum SurfaceState: Sendable {
        /// The surface closed or went away.
        case gone
        /// Live, with no frame yet.
        case waiting
        /// Its layer holds a frame.
        case framed
    }

    private let read: @MainActor () -> SurfaceState
    private var shown: (@MainActor () -> Void)?
    private var closed: (@MainActor () -> Void)?
    private var frames: FrameClient?

    /// Starts waiting.
    ///
    /// - Parameters:
    ///   - scheduler: The frame clock of the surface's window, read when the watch starts ticking.
    ///   - read: The surface's state, read now and at each frame while it waits.
    public init(scheduler: @escaping @MainActor () -> FrameScheduler, read: @escaping @MainActor () -> SurfaceState,
                shown: @escaping @MainActor () -> Void, closed: @escaping @MainActor () -> Void) {
        self.read = read
        self.shown = shown
        self.closed = closed
        guard !check() else { return }
        // Motion rate: the `create.tab` interval ends on that frame; most tabs tick once or twice.
        // frame-client: reads the surface view's presented frame until the first one shows (view state, on main)
        let frames = FrameClient(owner: "TerminalFirstFrameWatch", isAnimation: false, rate: .motion, scheduler: scheduler) { [weak self] _ in
            self?.check() == false
        }
        self.frames = frames
        frames.activate()
    }

    /// Whether it still waits.
    public var isWaiting: Bool { shown != nil }

    /// Whether its frame client is on its scheduler (it ticks only while it waits).
    public var isTicking: Bool { frames?.isActive == true }

    /// Stops waiting without running either callback.
    public func cancel() {
        (shown, closed) = (nil, nil)
        frames?.deactivate()
    }

    /// Runs a callback when the wait is over; true once over (the frame client then goes idle).
    private func check() -> Bool {
        guard let shown, let closed else { return true }
        switch read() {
        case .waiting:
            return false
        case .gone:
            (self.shown, self.closed) = (nil, nil)
            closed()
        case .framed:
            (self.shown, self.closed) = (nil, nil)
            shown()
        }
        return true
    }
}

extension TerminalSession {
    /// This terminal's first frame as a new tab's `create.tab` end (``TerminalFirstFrameWatch``); `content` is its
    /// view in the pane.
    public func createTabFirstFrame(content: AnyObject) -> CreateTabTimings.FirstFrame {
        .init(content: content) { [weak self] done in
            guard let self else {
                done(.closed)
                return nil
            }
            let watch = TerminalFirstFrameWatch(scheduler: { [weak self] in self.map { FrameScheduler.forView($0.surfaceView) } ?? .app },
                                                read: { [weak self] in self?.firstFrameState ?? .gone },
                                                shown: { done(.shown) }, closed: { done(.closed) })
            return { watch.cancel() }
        }
    }

    /// Runs `drawn` once at the first frame this terminal draws after its first content (the daemon's snapshot, a
    /// replay or output) is applied, or when its surface went first: the launch picture's part over the terminal leaves
    /// there. A frame on screen when the content was queued may still present on the next tick, so
    /// only a frame seen two ticks on counts, as ``TerminalFrameHold`` does. Returns what cancels the wait.
    public func whenContentFrameDrawn(_ drawn: @escaping @MainActor () -> Void) -> @MainActor () -> Void {
        let mark = ContentFrameMark()
        let watch = TerminalFirstFrameWatch(scheduler: { [weak self] in self.map { FrameScheduler.forView($0.surfaceView) } ?? .app },
                                            read: { [weak self] in
                                                guard let self, surfaceView.superview != nil else { return .gone }
                                                return mark.state(hasContent: surfaceHasContent, frame: surfaceView.presentedFrame)
                                            }, shown: drawn, closed: drawn)
        return { watch.cancel() }
    }

    /// `close()` takes the surface out of the session's view; a live session always has it there.
    private var firstFrameState: TerminalFirstFrameWatch.SurfaceState {
        guard surfaceView.superview != nil else { return .gone }
        return surfaceView.presentedFrame == nil ? .waiting : .framed
    }
}

/// The frame a terminal showed when its first content was applied, and the ticks since (``TerminalSession/whenContentFrameDrawn(_:)``).
@MainActor
private final class ContentFrameMark {
    private var atContent: (frame: AnyObject?, ticks: Int)?

    func state(hasContent: Bool, frame: AnyObject?) -> TerminalFirstFrameWatch.SurfaceState {
        guard hasContent else { return .waiting }
        guard var atContent else {
            self.atContent = (frame, 0)
            return .waiting
        }
        atContent.ticks += 1
        self.atContent = atContent
        guard atContent.ticks >= 2, let frame, frame !== atContent.frame else { return .waiting }
        return .framed
    }
}
