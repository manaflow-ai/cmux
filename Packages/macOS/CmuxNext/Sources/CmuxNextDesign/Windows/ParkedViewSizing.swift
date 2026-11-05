public import AppKit
import CmuxNextCompat
import CmuxNextDesignTokens

/// The views a container keeps parked (in the window, hidden: a pane's tabs that do not show) and their sizing
/// (FRAME OWNER REFACTOR S7b, `motion.frameOwner.parkedPages`). A parked view keeps its frame while its container
/// resizes, so a window's live resize or a pane's spring lays none of it out per frame (Chrome lays out no hidden box).
/// When the motion ends, each parked view whose frame is not the one it shows at takes that frame at the main run loop's
/// idle points, one view per pass and never while input waits in the queue, so a show later finds it sized and laid out
/// (HomeMessagesReinsertBench: a parked docked Home sized at its show cost 7.85 ms p50 against 3.08 ms). A show that
/// comes first sizes the view itself (``willShow(_:)``). Work for views the person cannot see, at idle, as Chrome
/// throttles hidden tabs; no timer.
@MainActor
public final class ParkedViewSizing {
    /// Whether parked views keep their frame and are sized at idle (`motion.frameOwner.parkedPages`).
    public static var isOn: Bool { MotionTunables.frameOwnerParkedPages.value }

    private struct Entry {
        weak var view: NSView?
    }

    /// The view the parked views are in.
    private weak var container: NSView?
    /// The frame `view` shows at in the container; nil: it is not a parked view that keeps its frame.
    private let showFrame: @MainActor (NSView) -> NSRect?
    /// Whether the container is in a motion now (a live resize, a spring, a person's drag): the idle point sizes nothing
    /// then, and the motion's end asks again.
    private let inMotion: @MainActor () -> Bool
    /// The views to size, in order, and whether an idle point is asked for.
    private var pending: [Entry] = []
    private var armed = false
    /// Whether input waits in the application's queue (the idle point does nothing then).
    var inputWaits: @MainActor () -> Bool = { ParkedViewSizing.applicationHasQueuedInput() }
    /// Calls its argument at the main run loop's next idle point: after AppKit's display and Core Animation's commit, one
    /// before `.max`, so work that waits for the pass's end (``AfterFrameCommit``) runs after it.
    var atIdlePoint: @MainActor (@escaping @MainActor () -> Void) -> Void = { body in
        MainRunLoopObserver.once(activities: .beforeWaiting, order: .max - 1, body)
    }

    /// - Parameters:
    ///   - container: The view the parked views are in.
    ///   - showFrame: The frame a parked view shows at now in `container` (also one parked elsewhere that comes in); nil
    ///     for one that does not keep its frame while parked.
    ///   - inMotion: Whether the container is in a motion now.
    public init(container: NSView, showFrame: @escaping @MainActor (NSView) -> NSRect?, inMotion: @escaping @MainActor () -> Bool) {
        self.container = container
        self.showFrame = showFrame
        self.inMotion = inMotion
    }

    /// A motion of the container ended (a window's live resize, a pane's spring) or it resized outside one: each of
    /// `views` whose frame is not its show frame is sized at the coming idle points. Replaces what was pending.
    public func motionDidEnd(_ views: [NSView]) {
        guard Self.isOn else { return }
        pending = views.filter { view in view.superview === container && showFrame(view).map { $0 != view.frame } ?? false }
            .map { Entry(view: $0) }
        arm()
    }

    /// `view` shows in the container now: it takes its show frame at once, before the container asks whether its paint
    /// holds, and leaves the queue. One parked in another container (a tab moved) takes the size it shows at, so the hold
    /// sees the change; the container puts it in place as it adds it.
    public func willShow(_ view: NSView) {
        guard Self.isOn else { return }
        pending.removeAll { $0.view == nil || $0.view === view }
        guard let frame = showFrame(view) else { return }
        if view.superview === container {
            if view.frame != frame { view.frame = frame }
        } else if view.frame.size != frame.size {
            view.setFrameSize(frame.size)
        }
    }

    private func arm() {
        guard !armed, !pending.isEmpty else { return }
        armed = true
        atIdlePoint { [weak self] in self?.idlePoint() }
    }

    /// One view per idle point. With input waiting, the next pass (the input's) tries again; after sizing one, the run
    /// loop wakes so the next view gets its own pass and what this one changed commits.
    private func idlePoint() {
        armed = false
        // Switched off since it armed, or a new motion runs (its end asks again): nothing to size now.
        guard Self.isOn, !inMotion() else { return pending.removeAll() }
        guard !inputWaits() else { return arm() }
        while let entry = pending.first {
            pending.removeFirst()
            guard let view = entry.view, view.superview === container, view.isHidden, let frame = showFrame(view), frame != view.frame else { continue }
            view.frame = frame
            view.layoutSubtreeIfNeeded()
            break
        }
        arm()
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }

    /// A key, a click or a scroll in the application's queue, read without running the run loop's sources: a mode with
    /// no sources only looks at the events AppKit already took from the window server.
    static func applicationHasQueuedInput() -> Bool {
        NSApp?.nextEvent(matching: Self.input, until: .distantPast, inMode: Self.peekMode, dequeue: false) != nil
    }

    private static let peekMode = RunLoop.Mode("com.cmux.parkedViewSizing.peek")
    private static let input: NSEvent.EventTypeMask = [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .leftMouseUp, .rightMouseDown,
                                                       .rightMouseUp, .otherMouseDown, .otherMouseUp, .leftMouseDragged,
                                                       .rightMouseDragged, .otherMouseDragged, .scrollWheel]
}

/// A view a pane parks that keeps its frame while it is parked (``ParkedViewSizing``): a chat or a native page.
@MainActor
public protocol ParkedFrameKeeping: NSView {
    /// Whether it keeps its frame while parked now; false: it follows its pane (a page that no hold covers at a new size).
    var keepsFrameWhileParked: Bool { get }
}

public extension ParkedFrameKeeping {
    var keepsFrameWhileParked: Bool { true }
}

/// The owner of a ``PaneContentAreaView`` (a pane): the frame each view parked in it shows at.
@MainActor
public protocol ParkedFrameSource: NSView {
    /// The frame `view` shows at, in the content area; nil when the owner places it itself.
    func parkedFrame(of view: NSView) -> NSRect?
}
