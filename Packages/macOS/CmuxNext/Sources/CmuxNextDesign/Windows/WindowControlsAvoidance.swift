public import AppKit
import CmuxNextCompat

/// A view in the window's top row that keeps its leading controls clear of the traffic lights
/// and the titlebar accessory (``TitlebarAccessoryHosting``) where they lie over it: Home's list
/// header in a pane with no tab bar, its chat's compose button. Its place in the window changes
/// with no resize of its own (the sidebar shows or hides, the toolbar band opens, a pane moves),
/// so no layout of its own runs then: the window asks each one to re-check (cmux#25593).
@MainActor
public protocol WindowControlsAvoiding: AnyObject {
    /// Re-measures against the window's top row; lays out again only when the clearance changed.
    func updateWindowControlsAvoidance()
}

/// A window that keeps the views avoiding its top row (``WindowControlsAvoiders``).
@MainActor
public protocol WindowControlsAvoidanceHosting: AnyObject {
    var windowControlsAvoiders: WindowControlsAvoiders { get }
}

/// One window's views that avoid its top row, held weakly. A view joins when it enters the
/// window (``join(_:)``); one that left the window or was freed drops out at the next update.
@MainActor
public final class WindowControlsAvoiders {
    private struct Entry { weak var view: (any WindowControlsAvoiding & NSView)? }
    private var entries: [ObjectIdentifier: Entry] = [:]

    public init() {}

    /// The number of views that joined and are still alive (tests).
    public var count: Int { entries.values.count(where: { $0.view != nil }) }

    public func add(_ view: any WindowControlsAvoiding & NSView) { entries[ObjectIdentifier(view)] = Entry(view: view) }

    /// Open ``batching(in:_:)`` calls on this window, and whether an update was asked inside them.
    private var batchDepth = 0
    private var batchedUpdate = false
    /// Ends a batch left open (``endBatchesLeftOpen(in:)``), from the first batch on.
    private var leftOpenWatch: MainRunLoopObserver?

    /// Runs `body`; the updates asked for in it (``update(in:)``, ``WindowControlsAvoiders/refresh(in:)``) run once,
    /// at its end: a layout frame that moves many panes, each of which asks, re-checks every view once, not once per
    /// pane. Nested calls end at the outermost one.
    public func batching<T>(in window: NSWindow, _ body: () -> T) -> T {
        if leftOpenWatch == nil { watchForBatchesLeftOpen(in: window) }
        batchDepth += 1
        defer {
            // Never below 0: a reset (``endBatchesLeftOpen(in:)``) inside the body ended this batch already.
            batchDepth = max(0, batchDepth - 1)
            if batchDepth == 0, batchedUpdate {
                batchedUpdate = false
                update(in: window)
            }
        }
        return body()
    }

    /// An Objective-C exception that AppKit catches in a layout pass or a frame change (a layout loop it stops) skips
    /// the Swift `defer` that ends ``batching(in:_:)``: the depth stayed above 0 and every later update waited for an
    /// end that never came, so Home's header and chat column stopped re-checking for the life of the window. When the
    /// main run loop goes to sleep, in any of its common modes (the app's event loop, a live resize's or a menu's
    /// tracking loop), no pass or frame change is under way unless it ran a nested run loop: a batch still open there
    /// was left open, and ends. (One under a nested loop ends early; its views re-read the lights in their own layout.)
    private func watchForBatchesLeftOpen(in window: NSWindow) {
        leftOpenWatch = MainRunLoopObserver(activities: .beforeWaiting) { [weak self, weak window] _ in
            guard let self, let window else { return }
            self.endBatchesLeftOpen(in: window)
        }
    }

    /// Ends the batches still open on `window` and runs the update asked in them.
    private func endBatchesLeftOpen(in window: NSWindow) {
        guard batchDepth > 0 else { return }
        batchDepth = 0
        guard batchedUpdate else { return }
        batchedUpdate = false
        update(in: window)
    }

    /// Each view still in `window` re-checks its clearance. A hidden one (a workspace not shown)
    /// waits: it re-checks when it shows again (its `viewDidUnhide`). Inside ``batching(in:_:)`` it runs at the
    /// batch's end.
    public func update(in window: NSWindow) {
        guard batchDepth == 0 else {
            batchedUpdate = true
            return
        }
        for (id, entry) in entries {
            guard let view = entry.view, view.window === window else {
                entries[id] = nil
                continue
            }
            guard !view.isHiddenOrHasHiddenAncestor else { continue }
            view.updateWindowControlsAvoidance()
        }
    }

    /// Re-checks a window's registered views when it hosts avoidance, including a caller with no window yet.
    public static func refresh(in window: NSWindow?) {
        guard let window, let host = window as? any WindowControlsAvoidanceHosting else { return }
        host.windowControlsAvoiders.update(in: window)
    }

    /// ``batching(in:_:)`` on `window`'s avoiders; `body` alone when the window keeps none.
    public static func batching<T>(in window: NSWindow?, _ body: () -> T) -> T {
        guard let window, let host = window as? any WindowControlsAvoidanceHosting else { return body() }
        return host.windowControlsAvoiders.batching(in: window, body)
    }

    /// Joins `view` to its window's avoiders, when the window keeps them.
    public static func join(_ view: any WindowControlsAvoiding & NSView) {
        (view.window as? any WindowControlsAvoidanceHosting)?.windowControlsAvoiders.add(view)
    }
}

extension WindowTitlebar {
    /// The rightmost edge of the traffic lights or `accessory` where they lie over the `shown`
    /// part of `rect`, all in window coordinates; nil when neither does (pure).
    public static func windowControlsMaxX(over rect: CGRect, shown: CGRect, lights: CGRect?, accessory: CGRect?) -> CGFloat? {
        let visible = rect.intersection(shown)
        guard !visible.isNull else { return nil }
        return [lights, accessory].compactMap(\.self).filter { frame in
            visible.minY < frame.maxY && visible.maxY > frame.minY && visible.minX < frame.maxX && visible.maxX > frame.minX
        }.map(\.maxX).max()
    }
}
