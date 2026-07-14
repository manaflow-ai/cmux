import AppKit

@MainActor
extension PortalSplitDividerRegion {
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

    private static func appendObserved(
        _ view: NSView,
        to observedViews: inout [NSView],
        ids: inout Set<ObjectIdentifier>
    ) {
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
