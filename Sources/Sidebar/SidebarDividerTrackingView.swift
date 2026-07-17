import AppKit
import SwiftUI

/// Native divider tracking for the sidebar resizers.
///
/// Runs the same synchronous mouse-tracking loop NSSplitView uses: from
/// mouseDown, events are pulled with `nextEvent(matching:)` until mouse-up,
/// and after each width update the runloop spins once in `.eventTracking`
/// mode so SwiftUI/Core Animation commit the new layout inside the loop,
/// then the window presents. The divider therefore stays glued to the
/// cursor with no async runloop hop, while the panes remain SwiftUI-owned
/// (both blend modes keep their existing geometry).
struct SidebarDividerTracker: NSViewRepresentable {
    let onBegan: () -> Void
    let onChanged: (CGFloat) -> Void
    let onEnded: () -> Void

    func makeNSView(context: Context) -> SidebarDividerTrackingView {
        let view = SidebarDividerTrackingView()
        view.onBegan = onBegan
        view.onChanged = onChanged
        view.onEnded = onEnded
        return view
    }

    func updateNSView(_ nsView: SidebarDividerTrackingView, context: Context) {
        nsView.onBegan = onBegan
        nsView.onChanged = onChanged
        nsView.onEnded = onEnded
    }
}

@MainActor
final class SidebarDividerTrackingView: NSView {
    var onBegan: (() -> Void)?
    var onChanged: ((CGFloat) -> Void)?
    var onEnded: (() -> Void)?

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    // Divider drags work without first activating the window, matching
    // NSSplitView.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        onBegan?()
        let startX = event.locationInWindow.x
        NSCursor.resizeLeftRight.push()
        defer {
            NSCursor.pop()
            onEnded?()
        }
        while true {
            guard let next = window.nextEvent(
                matching: [.leftMouseDragged, .leftMouseUp],
                until: .distantFuture,
                inMode: .eventTracking,
                dequeue: true
            ) else { continue }
            if next.type == .leftMouseUp {
                break
            }
            onChanged?(next.locationInWindow.x - startX)
            // Drain the SwiftUI/CA commit scheduled by the width write, then
            // present — all inside this event, like NSSplitView's own loop.
            RunLoop.current.run(mode: .eventTracking, before: Date())
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
    }
}
