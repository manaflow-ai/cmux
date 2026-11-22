public import AppKit
public import CmuxNextLayout
public import CmuxNextTabs

/// Drag a pane by its tab bar: onto another pane's center to swap them, onto an edge, a column gap or a dock band to move it there (cx-8bv1j, iTerm's pane drag). The
/// press starts on empty strip space; tabs, chips and + keep their own presses. In the window's top
/// row, where a plain press moves the window, Option-drag drags the pane. The pane under the pointer
/// previews with the join fill a tab drop shows (drop-zones DESIGN.md), the drop swaps, and Escape cancels.
@MainActor
public final class PaneSwapDrag: NSObject, NSGestureRecognizerDelegate {
    private weak var strip: TabStripView?
    private let pane: LayoutPaneID
    private let layout: () -> LayoutRootView?
    private let swap: (LayoutPaneID, LayoutPaneID) -> Void
    /// A drop on a pane's edge, a column gap or a dock band: the whole pane moves there (RFD 0022 item 2).
    private let move: (DropTarget) -> Void
    /// A tab of the pane keys the tab drag's hit test, which empties the pane (`removing:`).
    private let dragKey: () -> String?
    /// Where the press began (window coordinates), for the lift's offset.
    private var start: NSPoint = .zero
    /// The last mouse-down starts a pane drag (decided at the press, not where the pan begins).
    private var armed = false
    private var escapeMonitor: Any?

    public init(strip: TabStripView, pane: LayoutPaneID, layout: @escaping () -> LayoutRootView?,
         dragKey: @escaping () -> String? = { nil }, move: @escaping (DropTarget) -> Void = { _ in },
         swap: @escaping (LayoutPaneID, LayoutPaneID) -> Void) {
        self.dragKey = dragKey
        self.move = move
        self.strip = strip
        self.pane = pane
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

    /// Whether `event`, a mouse-down on `strip`, drags its pane: on empty strip space, with no
    /// modifier but Option, and in the top row only with Option.
    public static func starts(_ event: NSEvent, on strip: TabStripView) -> Bool {
        guard event.modifierFlags.intersection([.command, .control, .shift]).isEmpty else { return false }
        let point = event.locationInWindow
        guard strip.titlebarHit(at: strip.convert(point, from: nil)) == .empty else { return false }
        return event.modifierFlags.contains(.option) || strip.titlebarPress(atWindowPoint: point) == .staysPut
    }

    /// An Option-press in the top row that drags a pane: the window must not move for it.
    public static func claims(_ event: NSEvent, in window: NSWindow) -> Bool {
        guard event.modifierFlags.contains(.option), let frame = window.contentView?.superview else { return false }
        var view = frame.hitTest(frame.convert(event.locationInWindow, from: nil))
        while let current = view, !(current is TabStripView) { view = current.superview }
        guard let strip = view as? TabStripView, strip.gestureRecognizers.contains(where: { $0.delegate is PaneSwapDrag }) else { return false }
        return starts(event, on: strip)
    }

    public func gestureRecognizer(_ recognizer: NSGestureRecognizer, shouldAttemptToRecognizeWith event: NSEvent) -> Bool {
        // Only a press that drags the pane (empty strip space) is tried; a press on a tab, chip or +
        // is the strip's alone.
        guard event.type == .leftMouseDown else { return true }
        armed = strip.map { Self.starts(event, on: $0) } ?? false
        return armed
    }

    public func gestureRecognizerShouldBegin(_ recognizer: NSGestureRecognizer) -> Bool { armed }

    /// The target under the pointer, by a tab drag's own hit test with this pane as the one the drag empties: the same
    /// zones, previews and room rule as a tab (nil over the pane itself, where a drop leaves it in place).
    private func hit(_ layout: LayoutRootView, at windowPoint: NSPoint, dwell: CFTimeInterval = DragTunables.splitDwell.value) -> DropTarget? {
        guard let key = dragKey() else { return nil }
        let local = layout.convert(windowPoint, from: nil)
        let inside = layout.bounds.insetBy(dx: 0.5, dy: 0.5)
        let clamped = CGPoint(x: min(max(local.x, inside.minX), inside.maxX), y: min(max(local.y, inside.minY), inside.maxY))
        guard let target = layout.updateTabDrag(LayoutTabID(key), locationInWindow: layout.convert(clamped, to: nil), removing: pane,
                                                edgeDwell: dwell) else { return nil }
        if case .pane(pane, _) = target { layout.hideTabDragHighlight(); return nil }
        return target
    }

    @objc private func pan(_ recognizer: NSPanGestureRecognizer) {
        guard let layout = layout() else { return }
        let point = layout.convert(recognizer.location(in: layout), to: nil)
        switch recognizer.state {
        case .began, .changed:
            guard armed else { return }
            if recognizer.state == .began {
                start = point
                watchEscape(recognizer)
            }
            // The pane follows the pointer at full size, live; the target's preview is a tab drag's.
            layout.liftPane(pane, from: start, to: point)
            if hit(layout, at: point) == nil { layout.hideTabDragHighlight() }
        case .ended:
            // Escape disarmed it: the release moves nothing.
            let moves = armed
            let target = moves ? hit(layout, at: point, dwell: 0) : nil
            end(layout)
            switch target {
            case .pane(let other, .center): swap(pane, other)
            case let target?: move(target)
            case nil: break
            }
        default:
            end(layout)
        }
    }

    /// Escape cancels the drag: it ends here (outline gone, disarmed), and the recognizer turned
    /// off and on stops tracking.
    private func watchEscape(_ recognizer: NSPanGestureRecognizer) {
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak recognizer] event in
            guard event.keyCode == 53, let self, let recognizer else { return event }
            if let layout = layout() { end(layout) }
            recognizer.isEnabled = false
            recognizer.isEnabled = true
            return nil
        }
    }

    private func end(_ layout: LayoutRootView) {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
        armed = false
        layout.dropPaneLift()
        layout.cancelTabDrag()
    }
}
