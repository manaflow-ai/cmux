import AppKit
import CmuxNextBridge
import CmuxNextInput
import CmuxNextLayout
import CmuxNextTabs

/// Drag a pane by its tab bar onto another pane to swap them (cx-8bv1j, iTerm's pane drag). The
/// press starts on empty strip space; tabs, chips and + keep their own presses. In the window's top
/// row, where a plain press moves the window, Option-drag drags the pane. The pane under the pointer
/// previews with the join fill a tab drop shows (drop-zones DESIGN.md), the drop swaps, and Escape cancels.
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
    /// The windows' frame-aligned pointer input (feature `pointerFrameDrags`): the drag previews on a frame
    /// interval's first move and once more at its frame, at the latest point. Nil while it is off: each move previews.
    private let frames: PointerFrameCoalescers?
    /// The running drag's moves on its window's coalescer; nil between drags and with the feature off.
    private var moves: PointerFrameConsumer?
    /// Pane hit tests and previews run (tests: at most two per frame interval, its first move and the frame's latest).
    private(set) var previews = 0

    init(strip: TabStripView, pane: LayoutPaneID, input: InputEventTap, frames: PointerFrameCoalescers?,
         layout: @escaping () -> LayoutRootView?, swap: @escaping (LayoutPaneID, LayoutPaneID) -> Void) {
        self.strip = strip
        self.pane = pane
        self.input = input
        self.frames = frames
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
                  frames: pane.services.dragFrameInput, layout: { [weak pane] in pane?.workspace?.layoutView },
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
            // The start is the frame interval's first move: it previews at once, through the coalescer when there is one.
            moves = layout.window.flatMap { frames?.coalescer(for: $0) }?.consumer(owner: Self.movesOwner) { [weak self] input in
                self?.preview(atWindow: CGPoint(x: input.latest.location.x, y: input.latest.location.y))
            }
            move(to: point, in: layout)
        case .changed:
            guard armed else { return }
            move(to: point, in: layout)
        case .ended:
            // At the real release point; a move still waiting for its frame is older, and `end` drops it unpreviewed.
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

    /// One move of the drag to `point` (window coordinates). With the coalescer the preview follows a frame
    /// interval's first move at once and the frame's latest move at its frame, before the frame's drivers (Chromium's
    /// rAF-aligned input, `third_party/blink/renderer/platform/widget/input/main_thread_event_queue.cc`); without it
    /// every move previews.
    private func move(to point: CGPoint, in layout: LayoutRootView) {
        guard let moves, let window = layout.window else { return preview(atWindow: point) }
        moves.post(InputEventRecord(type: .leftMouseDragged, timestamp: ProcessInfo.processInfo.systemUptime,
                                    windowNumber: window.windowNumber, location: InputPoint(x: point.x, y: point.y)))
    }

    /// The pane under `point` (window coordinates) when it is not the dragged one.
    private func otherPane(atWindow point: CGPoint, in layout: LayoutRootView) -> LayoutPaneID? {
        layout.visiblePane(at: layout.convert(point, from: nil)).flatMap { $0.pane == pane ? nil : $0.pane }
    }

    /// Previews the drop at `point` (window coordinates): the pane under it shows the join fill. A
    /// drag that ended (released, Escape) before its frame shows nothing.
    private func preview(atWindow point: CGPoint) {
        guard armed, let layout = layout() else { return }
        previews += 1
        if let target = otherPane(atWindow: point, in: layout) {
            layout.showPaneDragTarget(target, locationInWindow: point)
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
        escape?.cancel()
        escape = nil
        armed = false
        layout?.cancelTabDrag()
    }
}
