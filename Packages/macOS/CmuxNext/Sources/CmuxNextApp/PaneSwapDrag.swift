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
    /// The app's input tap: Escape is heard there only while a drag is in flight.
    private let input: InputEventTap
    private var escapeSubscription: InputSubscription?

    init(strip: TabStripView, pane: LayoutPaneID, input: InputEventTap, layout: @escaping () -> LayoutRootView?,
         swap: @escaping (LayoutPaneID, LayoutPaneID) -> Void) {
        self.strip = strip
        self.pane = pane
        self.input = input
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
        guard let layout = layout() else { return }
        let target = layout.visiblePane(at: recognizer.location(in: layout)).flatMap { $0.pane == pane ? nil : $0 }
        switch recognizer.state {
        case .began, .changed:
            guard armed else { return }
            if recognizer.state == .began { watchEscape(recognizer) }
            if let target {
                layout.showPaneDragTarget(target.pane, locationInWindow: layout.convert(recognizer.location(in: layout), to: nil))
            } else {
                layout.hideTabDragHighlight()
            }
        case .ended:
            // Escape disarmed it: the release swaps nothing.
            let swaps = armed
            end(layout)
            if swaps, let target { swap(pane, target.pane) }
        default:
            end(layout)
        }
    }

    /// Escape cancels the drag: it ends here (outline gone, disarmed), and the recognizer turned
    /// off and on stops tracking. A drag-session intercept on the input tap, held only while the drag
    /// lasts (R-monitor), as the strip holds its tab drag's Escape (`TabStripEscape.dragCancel`).
    private func watchEscape(_ recognizer: NSPanGestureRecognizer) {
        escapeSubscription?.cancel()
        escapeSubscription = input.subscribe(class: .key, phase: .intercept(order: .dragSession)) { [weak self, weak recognizer] event in
            guard event.type == .keyDown, event.keyCode == 53, let self, let recognizer else { return .pass }
            if let layout = layout() { end(layout) }
            recognizer.isEnabled = false
            recognizer.isEnabled = true
            return .consume
        }
    }

    private func end(_ layout: LayoutRootView) {
        escapeSubscription?.cancel()
        escapeSubscription = nil
        armed = false
        layout.cancelTabDrag()
    }
}
