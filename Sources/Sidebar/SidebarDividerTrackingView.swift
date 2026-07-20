import AppKit
import QuartzCore
import SwiftUI

/// Native divider tracking for the sidebar resizers.
///
/// Runs the same synchronous mouse-tracking loop NSSplitView uses: from
/// mouseDown, events are pulled with `nextEvent(matching:)` until mouse-up,
/// and after each width update the runloop sleeps briefly in `.eventTracking`
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

#if DEBUG
    // Routing diagnosis: sidebar-resize bugs have historically been fights
    // over who wins pointer hit-testing (portal vs SwiftUI vs this view).
    // Log the winning view class for each left mouse-down so a stolen drag
    // is attributable from the debug log alone.
    private static var diagnosticsInstalled = false
    private static func installDiagnosticsIfNeeded() {
        guard !diagnosticsInstalled else { return }
        diagnosticsInstalled = true
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { event in
            if let contentView = event.window?.contentView {
                let point = contentView.convert(event.locationInWindow, from: nil)
                let hit = contentView.hitTest(point)
                cmuxDebugLog(
                    "sidebar.divider.downRouting x=\(Int(event.locationInWindow.x)) " +
                    "hit=\(hit.map { String(describing: type(of: $0)) } ?? "nil")"
                )
            }
            return event
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { Self.installDiagnosticsIfNeeded() }
    }
#endif

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
        var eventCount = 0
        var writeMs = 0.0, commitMs = 0.0, layoutMs = 0.0, displayMs = 0.0, flushMs = 0.0
        NSCursor.resizeLeftRight.push()
        let startedAt = CACurrentMediaTime()
        defer {
            NSCursor.pop()
            onEnded?()
#if DEBUG
            let fmt = { (v: Double) in String(format: "%.0f", v * 1000) }
            cmuxDebugLog(
                "sidebar.divider.drag events=\(eventCount) " +
                "duration=\(fmt(CACurrentMediaTime() - startedAt))ms " +
                "write=\(fmt(writeMs)) commit=\(fmt(commitMs)) layout=\(fmt(layoutMs)) " +
                "display=\(fmt(displayMs)) caFlush=\(fmt(flushMs))"
            )
#endif
        }
        while true {
            guard var next = window.nextEvent(
                matching: [.leftMouseDragged, .leftMouseUp],
                until: .distantFuture,
                inMode: .eventTracking,
                dequeue: true
            ) else { continue }
            // Track the newest queued position: high-polling mice deliver
            // drags faster than frames present, and replaying stale ones
            // would put the divider behind the cursor.
            while next.type == .leftMouseDragged,
                  let queued = window.nextEvent(
                      matching: [.leftMouseDragged, .leftMouseUp],
                      until: Date(),
                      inMode: .eventTracking,
                      dequeue: true
                  ) {
                next = queued
            }
            if next.type == .leftMouseUp {
                break
            }
            eventCount += 1
            let t0 = CACurrentMediaTime()
            onChanged?(next.locationInWindow.x - startX)
            let t1 = CACurrentMediaTime()
            // A zero-deadline runloop pass returns before the before-waiting
            // phase, which is where SwiftUI and Core Animation register their
            // commit observers — so the width write would present a frame (or
            // more) late. A real 1ms deadline lets the loop reach that phase
            // and commit inside this event; then present.
            RunLoop.current.run(mode: .eventTracking, before: Date(timeIntervalSinceNow: 0.001))
            let t2 = CACurrentMediaTime()
            window.contentView?.layoutSubtreeIfNeeded()
            let t3 = CACurrentMediaTime()
            window.displayIfNeeded()
            let t4 = CACurrentMediaTime()
            CATransaction.flush()
            let t5 = CACurrentMediaTime()
            writeMs += t1 - t0
            commitMs += t2 - t1
            layoutMs += t3 - t2
            displayMs += t4 - t3
            flushMs += t5 - t4
        }
    }
}
