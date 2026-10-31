public import AppKit

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

    /// Each view still in `window` re-checks its clearance. A hidden one (a workspace not shown)
    /// waits: it re-checks when it shows again (its `viewDidUnhide`).
    public func update(in window: NSWindow) {
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
