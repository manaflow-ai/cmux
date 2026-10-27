import AppKit
import CmuxNextBridge
import CmuxNextInput
import CmuxNextLayout
import CmuxNextTabs
import CmuxNextWakeups

/// Drag a pane by its tab bar onto another pane to swap them (cx-8bv1j, iTerm's pane drag). The
/// press starts on empty strip space; tabs, chips and + keep their own presses. In the window's top
/// row, where a plain press moves the window, Option-drag drags the pane. The pane under the pointer
/// previews with the join fill a tab drop shows (drop-zones DESIGN.md), the drop swaps, and Escape cancels.
///
/// With the layout's frame-aligned drag input (feature `pointerFrameDrags`) the preview follows a frame interval's
/// first move at once and the frame's latest move at its frame; with its resampler (feature `resampledDrags`) the
/// preview's pointer is drawn resampled at the frame's time. The target pane and the drop read the real pointer.
@MainActor
final class PaneSwapDrag: NSObject, NSGestureRecognizerDelegate {
    private weak var strip: TabStripView?
    private let pane: LayoutPaneID
    private let layout: () -> LayoutRootView?
    private let swap: (LayoutPaneID, LayoutPaneID) -> Void
    /// The last mouse-down starts a pane drag (decided at the press, not where the pan begins).
    private var armed = false
    /// The app's input tap: Escape is an intercept on it while a drag runs.
    private let input: InputEventTap
    /// The drag's Escape intercept; nil while no drag runs.
    private var escape: InputSubscription?
    /// The running drag's moves on its window's coalescer (``LayoutRootView/dragFrameInput``); nil between drags
    /// and without frame-aligned input: each move previews.
    private var moves: PointerFrameConsumer?
    /// The running drag's resampler (``LayoutRootView/newDragResampler()``); nil: the preview's pointer is the real one.
    private var resampler: DragResampler?
    /// The time of a drag move, on `NSEvent.timestamp`'s clock (seconds since boot): the pan recognizer gives none.
    private let now: () -> TimeInterval
    /// Where the preview's pointer was last drawn (window coordinates); nil before the drag's first preview.
    private(set) var shownPointer: CGPoint?

    init(strip: TabStripView, pane: LayoutPaneID, input: InputEventTap, layout: @escaping () -> LayoutRootView?,
         swap: @escaping (LayoutPaneID, LayoutPaneID) -> Void, now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.strip = strip
        self.pane = pane
        self.input = input
        self.now = now
        self.layout = layout
        self.swap = swap
        super.init()
        let recognizer = NSPanGestureRecognizer(target: self, action: #selector(pan(_:)))
        // A press on a tab goes to the strip at once, which selects on mouse-down (u2814): while a
        // recognizer that delays the primary button is possible, AppKit holds the mouse-down from the
        // view until the recognizer fails at the release, so every pane tab switched on mouse-up.
        recognizer.delaysPrimaryMouseButtonEvents = false
        recognizer.delegate = self
        strip.addGestureRecognizer(recognizer)
    }

    /// A pane's drag: a drop sends `swap-pane` to its daemon.
    convenience init(pane: PaneController) {
        self.init(strip: pane.view.stripView, pane: pane.layoutPaneID, input: pane.services.inputTap,
                  layout: { [weak pane] in pane?.workspace?.layoutView },
                  swap: { [weak pane] from, to in
                      guard let pane, let content = pane.workspace, let from = content.handles.panes[from],
                            let to = content.handles.panes[to] else { return }
                      pane.daemon.send("swap-pane") { try await $0.swapPane(from, with: .pane(to)) }
                  })
    }

    /// Whether `event`, a mouse-down on `strip`, drags its pane: on empty strip space, with no
    /// modifier but Option, and in the top row only with Option.
    static func starts(_ event: NSEvent, on strip: TabStripView) -> Bool {
        guard event.modifierFlags.intersection([.command, .control, .shift]).isEmpty else { return false }
        let point = event.locationInWindow
        guard strip.titlebarHit(at: strip.convert(point, from: nil)) == .empty else { return false }
        return event.modifierFlags.contains(.option) || strip.titlebarPress(atWindowPoint: point) == .staysPut
    }

    /// An Option-press in the top row that drags a pane: the window must not move for it.
    static func claims(_ event: NSEvent, in window: NSWindow) -> Bool {
        guard event.modifierFlags.contains(.option), let frame = window.contentView?.superview else { return false }
        var view = frame.hitTest(frame.convert(event.locationInWindow, from: nil))
        while let current = view, !(current is TabStripView) { view = current.superview }
        guard let strip = view as? TabStripView, strip.gestureRecognizers.contains(where: { $0.delegate is PaneSwapDrag }) else { return false }
        return starts(event, on: strip)
    }

    func gestureRecognizer(_ recognizer: NSGestureRecognizer, shouldAttemptToRecognizeWith event: NSEvent) -> Bool {
        // Only a press that drags the pane (empty strip space) is tried; a press on a tab, chip or +
        // is the strip's alone.
        guard event.type == .leftMouseDown else { return true }
        armed = strip.map { Self.starts(event, on: $0) } ?? false
        return armed
    }

    func gestureRecognizerShouldBegin(_ recognizer: NSGestureRecognizer) -> Bool { armed }

    @objc private func pan(_ recognizer: NSPanGestureRecognizer) {
        guard let layout = layout() else {
            // The layout went during the drag: an end still drops the drag's Escape intercept.
            if recognizer.state != .began, recognizer.state != .changed { end(nil) }
            return
        }
        let point = recognizer.location(in: nil)
        switch recognizer.state {
        case .began:
            guard armed else { return }
            watchEscape(recognizer)
            moves = layout.window.flatMap { layout.dragFrameInput?.coalescer(for: $0) }?
                .frameTimedConsumer(owner: Self.movesOwner) { [weak self] input, frame in self?.deliver(input, at: frame) }
            resampler = moves == nil ? nil : layout.newDragResampler()
            move(to: point, in: layout)
        case .changed:
            guard armed else { return }
            move(to: point, in: layout)
        case .ended:
            // At the real release point; a move still waiting for its frame is older, and `end` drops it.
            // Escape disarmed it: the release swaps nothing.
            let target = otherPane(atWindow: point, in: layout)
            let swaps = armed
            end(layout)
            if swaps, let target { swap(pane, target) }
        default:
            end(layout)
        }
    }

    /// The coalescer owner of a pane drag's moves.
    static let movesOwner = "PaneSwapDrag.moves"

    /// One move of the drag to `point` (window coordinates): through the frame-aligned input when there is
    /// some (Chromium's rAF-aligned input, `third_party/blink/renderer/platform/widget/input/main_thread_event_queue.cc`),
    /// else a preview now.
    private func move(to point: CGPoint, in layout: LayoutRootView) {
        guard let moves, let window = layout.window else { return preview(real: point, shown: nil, in: layout) }
        moves.post(InputEventRecord(type: .leftMouseDragged, timestamp: now(), windowNumber: window.windowNumber,
                                    location: InputPoint(x: point.x, y: point.y)))
    }

    /// One delivery of the drag's moves: the target at the latest real point, the preview's pointer resampled at
    /// `frame` while a resampler runs (Chromium's `MainThreadEventQueue::HandleEventResampling`). A drag that ended
    /// before its frame previews nothing.
    private func deliver(_ input: PointerCoalescedInput, at frame: PointerFrameTime) {
        guard armed, let layout = layout() else { return }
        let real = CGPoint(x: input.latest.location.x, y: input.latest.location.y)
        let shown = resampler?.points(for: input, at: frame).visualPoint
        preview(real: real, shown: shown.map { CGPoint(x: $0.x, y: $0.y) }, in: layout)
    }

    /// The pane under `point` (window coordinates) when it is not the dragged one.
    private func otherPane(atWindow point: CGPoint, in layout: LayoutRootView) -> LayoutPaneID? {
        layout.visiblePane(at: layout.convert(point, from: nil)).flatMap { $0.pane == pane ? nil : $0.pane }
    }

    /// Previews the drop for the real pointer `real` (window coordinates): the pane under it shows the join
    /// fill, drawn from the pointer at `shown` (nil: at `real`).
    private func preview(real: CGPoint, shown: CGPoint?, in layout: LayoutRootView) {
        let pointer = shown ?? real
        shownPointer = pointer
        if let target = otherPane(atWindow: real, in: layout) {
            layout.showPaneDragTarget(target, locationInWindow: pointer)
        } else {
            layout.hideTabDragHighlight()
        }
    }

    /// Escape cancels the drag: it ends here (outline gone, disarmed), and the recognizer turned
    /// off and on stops tracking. The intercept lives for the drag only (``end(_:)`` cancels it).
    private func watchEscape(_ recognizer: NSPanGestureRecognizer) {
        escape = input.subscribe(class: .key, phase: .intercept(order: .dragSession)) { [weak self, weak recognizer] event in
            guard event.type == .keyDown, event.keyCode == 53, let self, let recognizer else { return .pass }
            end(layout())
            recognizer.isEnabled = false
            recognizer.isEnabled = true
            return .consume
        }
    }

    /// Ends the drag on every path: the Escape intercept goes, the drag disarms, the preview hides.
    private func end(_ layout: LayoutRootView?) {
        moves?.cancel()
        moves = nil
        resampler = nil
        escape?.cancel()
        escape = nil
        armed = false
        layout?.cancelTabDrag()
    }
}
