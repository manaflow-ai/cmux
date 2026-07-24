import AppKit

/// Divider hover cursors are asserted manually from `.activeAlways` tracking
/// areas, which AppKit delivers even when another window covers this one at
/// the pointer. Gate `NSCursor.set()` on the host window actually being the
/// topmost mouse target so a backgrounded window cannot flip the cursor
/// through an overlapping window (same bug class as the sidebar resizer
/// occlusion fix).
@MainActor
struct PortalDividerCursorOcclusion {
    var topmostMouseEventWindowNumber: (NSPoint) -> Int? = { screenPoint in
        let windowNumber = NSWindow.windowNumber(at: screenPoint, belowWindowWithWindowNumber: 0)
        return windowNumber > 0 ? windowNumber : nil
    }

    func mayAssertDividerCursor(screenPoint: NSPoint, windowNumber: Int) -> Bool {
        topmostMouseEventWindowNumber(screenPoint) == windowNumber
    }

    func mayAssertDividerCursor(in window: NSWindow?) -> Bool {
        guard let window else { return false }
        return mayAssertDividerCursor(
            screenPoint: NSEvent.mouseLocation,
            windowNumber: window.windowNumber
        )
    }
}

/// Orientation of a hovered split divider and the resize cursor it shows.
/// Shared by the portal host views and the hosted web-inspector divider.
enum PortalDividerCursorKind: Equatable {
    case vertical
    case horizontal

    var cursor: NSCursor {
        switch self {
        case .vertical: return .resizeLeftRight
        case .horizontal: return .resizeUpDown
        }
    }
}

@MainActor
final class PortalSplitDividerRegion {
    weak var splitView: NSSplitView?
    weak var window: NSWindow?
    let dividerIndex: Int
    let rectInWindow: NSRect
    let boundsInWindow: NSRect
    let isVertical: Bool
    let isInHostedContent: Bool

    /// Extra points on each side of the hairline divider that show the resize
    /// cursor and accept a divider drag. Bonsplit's drag effective rect is fed
    /// the same value (see `Workspace.bonsplitAppearance`), so every point
    /// that shows the cursor can start a drag.
    static let dividerHitExpansion: CGFloat = 8

    init(
        splitView: NSSplitView,
        dividerIndex: Int,
        rectInWindow: NSRect,
        boundsInWindow: NSRect,
        isVertical: Bool,
        isInHostedContent: Bool = false
    ) {
        self.splitView = splitView
        self.window = splitView.window
        self.dividerIndex = dividerIndex
        self.rectInWindow = rectInWindow
        self.boundsInWindow = boundsInWindow
        self.isVertical = isVertical
        self.isInHostedContent = isInHostedContent
    }

    var isLive: Bool {
        guard let splitView,
              let window,
              splitView.window === window,
              dividerIndex + 1 < splitView.arrangedSubviews.count,
              splitView.isVertical == isVertical else {
            return false
        }
        var current: NSView? = splitView
        while let view = current {
            if view.isHidden { return false }
            current = view.superview
        }
        let first = splitView.arrangedSubviews[dividerIndex].frame
        let second = splitView.arrangedSubviews[dividerIndex + 1].frame
        if isVertical {
            return first.width > 1 || second.width > 1
        }
        return first.height > 1 || second.height > 1
    }

    static func allLive(_ regions: [PortalSplitDividerRegion]) -> Bool {
        regions.allSatisfy(\.isLive)
    }

    var hitRectInWindow: NSRect {
        rectInWindow
            .insetBy(dx: -Self.dividerHitExpansion, dy: -Self.dividerHitExpansion)
            .intersection(boundsInWindow)
    }

    static func dividerRect(in splitView: NSSplitView, dividerIndex: Int) -> NSRect? {
        guard dividerIndex >= 0,
              dividerIndex + 1 < splitView.arrangedSubviews.count else {
            return nil
        }

        let first = splitView.arrangedSubviews[dividerIndex].frame
        let second = splitView.arrangedSubviews[dividerIndex + 1].frame
        let thickness = splitView.dividerThickness
        if splitView.isVertical {
            guard first.width > 1 || second.width > 1 else { return nil }
            return NSRect(x: max(0, first.maxX), y: 0, width: thickness, height: splitView.bounds.height)
        }

        guard first.height > 1 || second.height > 1 else { return nil }
        return NSRect(x: 0, y: max(0, first.maxY), width: splitView.bounds.width, height: thickness)
    }

    static func dividerHitRect(in splitView: NSSplitView, dividerIndex: Int) -> NSRect? {
        guard let dividerRect = dividerRect(in: splitView, dividerIndex: dividerIndex) else { return nil }
        return dividerRect
            .insetBy(dx: -Self.dividerHitExpansion, dy: -Self.dividerHitExpansion)
            .intersection(splitView.bounds)
    }

    static func dividerHitRectInWindow(in splitView: NSSplitView, dividerIndex: Int) -> NSRect? {
        guard let hitRect = dividerHitRect(in: splitView, dividerIndex: dividerIndex) else { return nil }
        let hitRectInWindow = splitView.convert(hitRect, to: nil)
        guard hitRectInWindow.width > 0, hitRectInWindow.height > 0 else { return nil }
        return hitRectInWindow
    }

    static func collect(
        in rootView: NSView,
        hostView: NSView? = nil
    ) -> (regions: [PortalSplitDividerRegion], geometryObservedViews: [NSView], structureObservedViews: [NSView]) {
        var regions: [PortalSplitDividerRegion] = []
        var geometryObservedViews: [NSView] = []
        var geometryObservedIds = Set<ObjectIdentifier>()
        var structureObservedViews: [NSView] = []
        var structureObservedIds = Set<ObjectIdentifier>()
        var ancestorStack: [NSView] = []
        appendObserved(rootView, to: &geometryObservedViews, ids: &geometryObservedIds)
        appendObserved(rootView, to: &structureObservedViews, ids: &structureObservedIds)
        for subview in rootView.subviews {
            appendObserved(subview, to: &geometryObservedViews, ids: &geometryObservedIds)
            appendObserved(subview, to: &structureObservedViews, ids: &structureObservedIds)
        }
        collect(
            in: rootView,
            hostView: hostView,
            ancestorHidden: false,
            ancestorStack: &ancestorStack,
            into: &regions,
            geometryObservedViews: &geometryObservedViews,
            geometryObservedIds: &geometryObservedIds,
            structureObservedViews: &structureObservedViews,
            structureObservedIds: &structureObservedIds
        )
        return (regions, geometryObservedViews, structureObservedViews)
    }

    private static func collect(
        in view: NSView,
        hostView: NSView?,
        ancestorHidden: Bool,
        ancestorStack: inout [NSView],
        into result: inout [PortalSplitDividerRegion],
        geometryObservedViews: inout [NSView],
        geometryObservedIds: inout Set<ObjectIdentifier>,
        structureObservedViews: inout [NSView],
        structureObservedIds: inout Set<ObjectIdentifier>
    ) {
        let isHidden = ancestorHidden || view.isHidden

        if let splitView = view as? NSSplitView {
            for ancestor in ancestorStack {
                appendObserved(ancestor, to: &geometryObservedViews, ids: &geometryObservedIds)
                appendObserved(ancestor, to: &structureObservedViews, ids: &structureObservedIds)
            }
            appendObserved(splitView, to: &geometryObservedViews, ids: &geometryObservedIds)
            appendObserved(splitView, to: &structureObservedViews, ids: &structureObservedIds)
            for arrangedSubview in splitView.arrangedSubviews {
                appendObserved(arrangedSubview, to: &structureObservedViews, ids: &structureObservedIds)
            }
            if !isHidden {
                appendDividerRegions(for: splitView, hostView: hostView, into: &result)
            }
        }

        ancestorStack.append(view)
        defer { ancestorStack.removeLast() }

        for subview in view.subviews {
            collect(
                in: subview,
                hostView: hostView,
                ancestorHidden: isHidden,
                ancestorStack: &ancestorStack,
                into: &result,
                geometryObservedViews: &geometryObservedViews,
                geometryObservedIds: &geometryObservedIds,
                structureObservedViews: &structureObservedViews,
                structureObservedIds: &structureObservedIds
            )
        }
    }

    private static func appendObserved(_ view: NSView, to observedViews: inout [NSView], ids: inout Set<ObjectIdentifier>) {
        if ids.insert(ObjectIdentifier(view)).inserted {
            observedViews.append(view)
        }
    }

    private static func appendDividerRegions(
        for splitView: NSSplitView,
        hostView: NSView?,
        into result: inout [PortalSplitDividerRegion]
    ) {
        let splitBoundsInWindow = splitView.convert(splitView.bounds, to: nil)
        let dividerCount = max(0, splitView.arrangedSubviews.count - 1)
        for dividerIndex in 0..<dividerCount {
            guard let dividerRect = dividerRect(in: splitView, dividerIndex: dividerIndex) else { continue }
            let dividerRectInWindow = splitView.convert(dividerRect, to: nil)
            guard dividerRectInWindow.width > 0, dividerRectInWindow.height > 0 else { continue }
            result.append(PortalSplitDividerRegion(
                splitView: splitView,
                dividerIndex: dividerIndex,
                rectInWindow: dividerRectInWindow,
                boundsInWindow: splitBoundsInWindow,
                isVertical: splitView.isVertical,
                isInHostedContent: hostView.map { splitView.isDescendant(of: $0) } ?? false
            ))
        }
    }
}
