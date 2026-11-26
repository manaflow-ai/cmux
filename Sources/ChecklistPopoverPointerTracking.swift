import AppKit
import SwiftUI
/// Item-row frames in ``SidebarWorkspaceChecklistPopover``'s pointer
/// coordinate space, keyed by item id. Feeds the geometry-derived
/// `hoveredItemId` (see its doc comment).
struct ChecklistPopoverRowFramesKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] { [:] }
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// AppKit-owned pointer tracking for the checklist popover: one
/// NSTrackingArea on a background NSView that fills the popover content,
/// reporting the pointer's location in that view's (flipped, top-left
/// origin) coordinates — directly comparable to the row frames collected in
/// the popover's named coordinate space. `nil` means the pointer left the
/// popover.
///
/// Why not SwiftUI `.onContinuousHover`/`.onHover`: their tracking areas are
/// torn down and recreated whenever the owning view updates, so the first
/// mouse event after a checklist mutation can be a spurious `.ended` from
/// the stale area with no follow-up `.active` until the NEXT event — the
/// pointer-resting delete-x dropout. This view's backing NSView persists
/// across SwiftUI content updates, so its tracking area only changes with
/// geometry (`updateTrackingAreas`), never with content.
///
/// Also seeds the location from `NSEvent.mouseLocation` at window attach, so
/// a popover that (re)presents underneath an already-resting pointer knows
/// where it is before any mouse-moved arrives.
struct PopoverPointerTracker: NSViewRepresentable {
    let onPointerChange: @MainActor (CGPoint?) -> Void

    final class TrackerView: NSView {
        var onPointerChange: (@MainActor (CGPoint?) -> Void)?

        // SwiftUI's named coordinate space is top-left origin; matching that
        // here keeps reported points directly comparable to the row frames
        // collected via preference.
        override var isFlipped: Bool { true }

        // Tracking areas fire from geometry alone; this view must never win
        // hit testing over the SwiftUI buttons/fields/gestures it sits
        // behind (same contract as `HoverTrackingNSView`).
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(
                rect: .zero,
                // `.activeAlways` so hover keeps working when the terminal
                // pane steals key/main status back from the popover window.
                options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                owner: self,
                userInfo: nil
            ))
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            updateTrackingAreas()
            reportCurrentPointerLocation()
        }

        override func mouseEntered(with event: NSEvent) {
            report(event)
        }

        override func mouseMoved(with event: NSEvent) {
            report(event)
        }

        override func mouseExited(with event: NSEvent) {
            onPointerChange?(nil)
        }

        private func report(_ event: NSEvent) {
            let local = convert(event.locationInWindow, from: nil)
            onPointerChange?(local)
        }

        /// Reads the pointer position directly (no event needed) — used to
        /// seed hover state when the popover attaches under a resting pointer.
        private func reportCurrentPointerLocation() {
            guard let window else { return }
            let windowPoint = window.convertPoint(fromScreen: NSEvent.mouseLocation)
            let local = convert(windowPoint, from: nil)
            onPointerChange?(bounds.contains(local) ? local : nil)
        }
    }

    func makeNSView(context: Context) -> NSView {
        let view = TrackerView()
        view.onPointerChange = onPointerChange
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? TrackerView)?.onPointerChange = onPointerChange
    }
}
