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

/// A point where a vertical and a horizontal divider's hit bands overlap.
/// Only dividers from the same nested split tree pair up, so unrelated
/// splits (e.g. the dock sidebar next to the main tree) never co-drag.
struct PortalDividerIntersection {
    let vertical: PortalSplitDividerRegion
    let horizontal: PortalSplitDividerRegion
}

/// Divider regions hit at a single window point. Candidates are ordered
/// nearest-first per orientation (expanded hit bands of parallel dividers can
/// overlap around a narrow pane, and the pair must form the corner the
/// pointer is actually on). `first` is the topmost hit in z-order, preserving
/// the legacy precedence for single-axis cursor and routing decisions.
@MainActor
struct PortalDividerHits {
    /// A divider whose intersection zone (±`intersectionHitExpansion`,
    /// unclipped) contains the point. `isInSingleAxisBand` marks the subset
    /// inside the narrower clipped single-axis band (±`dividerHitExpansion`),
    /// which is what standalone resize cursors and native drags key on.
    struct Candidate {
        let region: PortalSplitDividerRegion
        let isInSingleAxisBand: Bool
    }

    let verticalCandidates: [Candidate]
    let horizontalCandidates: [Candidate]
    let first: PortalSplitDividerRegion?

    var vertical: PortalSplitDividerRegion? {
        verticalCandidates.first(where: \.isInSingleAxisBand)?.region
    }

    var horizontal: PortalSplitDividerRegion? {
        horizontalCandidates.first(where: \.isInSingleAxisBand)?.region
    }

    /// The two-axis pair at this point: the nearest vertical/horizontal
    /// combination that meets at a real pane corner of one nested split
    /// tree. Pairing uses the wider intersection zone so the corner is easy
    /// to grab from any quadrant; trying candidates nearest-first (instead
    /// of only the single nearest hit per orientation) keeps a valid corner
    /// drag available when the nearest hit of one orientation belongs to an
    /// unrelated tree.
    var intersection: PortalDividerIntersection? {
        for vertical in verticalCandidates where !vertical.region.isInHostedContent {
            for horizontal in horizontalCandidates where !horizontal.region.isInHostedContent {
                if PortalSplitDividerRegion.areNested(vertical.region, horizontal.region) {
                    return PortalDividerIntersection(vertical: vertical.region, horizontal: horizontal.region)
                }
            }
        }
        return nil
    }

    /// Every divider that participates in one visually aligned corner. This
    /// expands a nested pair into the matching divider on the opposite side
    /// of a 2×2 grid when its line starts within the alignment tolerance.
    /// The drag controller can then move the shared row/column as one unit.
    var alignedIntersectionRegions: (vertical: [PortalSplitDividerRegion], horizontal: [PortalSplitDividerRegion])? {
        guard let anchor = intersection else { return nil }
        let tolerance = PortalSplitDividerRegion.alignedIntersectionTolerance
        let vertical = verticalCandidates.map(\.region).filter { candidate in
            !candidate.isInHostedContent &&
                PortalSplitDividerRegion.areNested(candidate, anchor.horizontal) &&
                abs(candidate.rectInWindow.midX - anchor.vertical.rectInWindow.midX) <= tolerance
        }
        let horizontal = horizontalCandidates.map(\.region).filter { candidate in
            !candidate.isInHostedContent &&
                PortalSplitDividerRegion.areNested(candidate, anchor.vertical) &&
                abs(candidate.rectInWindow.midY - anchor.horizontal.rectInWindow.midY) <= tolerance
        }
        return (
            PortalSplitDividerRegion.uniqueRegions(vertical),
            PortalSplitDividerRegion.uniqueRegions(horizontal)
        )
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
    static let dividerHitExpansion: CGFloat = 10

    /// Extra points on each side of a divider line that count toward a
    /// two-axis intersection. Wider than the single-axis band and not
    /// clipped to the split's bounds, so the corner zone is an easy
    /// ~28x28pt target covering all four quadrants of the junction.
    static let intersectionHitExpansion: CGFloat = 14

    /// Parallel dividers this close to the chosen corner are treated as one
    /// aligned row or column. This covers slightly uneven 2×2 grids without
    /// pulling a visibly separate divider into the drag.
    static let alignedIntersectionTolerance: CGFloat = 14

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

    /// Whether the divider's content is actually visible to the user.
    /// Bonsplit's keepAllAlive lifecycle parks inactive tab content at SwiftUI
    /// opacity(0) with hit testing disabled instead of hiding it, which
    /// surfaces as a zero-alpha platform ancestor. Dividers inside such
    /// content must not pair into intersection drags (a drag would mutate an
    /// invisible split the click could never reach natively). Kept separate
    /// from `isLive`, which the portal hosts use for structural cache reuse:
    /// folding this in there would make a parked divider permanently
    /// non-live and force a full-tree recollect on every pointer event.
    var isInteractable: Bool {
        var current: NSView? = splitView
        while let view = current {
            if view.alphaValue == 0 { return false }
            if let layer = view.layer, layer.opacity == 0 { return false }
            current = view.superview
        }
        return true
    }

    var hitRectInWindow: NSRect {
        if isVertical {
            return NSRect(
                x: rectInWindow.midX - Self.dividerHitExpansion,
                y: boundsInWindow.minY,
                width: Self.dividerHitExpansion * 2,
                height: boundsInWindow.height
            )
        }
        return NSRect(
            x: boundsInWindow.minX,
            y: rectInWindow.midY - Self.dividerHitExpansion,
            width: boundsInWindow.width,
            height: Self.dividerHitExpansion * 2
        )
    }

    /// Deliberately unclipped: the corner of a nested split sits on the
    /// inner split's bounds edge, and clipping would cut the zone to one
    /// side of the junction.
    var intersectionHitRectInWindow: NSRect {
        rectInWindow.insetBy(dx: -Self.intersectionHitExpansion, dy: -Self.intersectionHitExpansion)
    }

    /// Hit regions at `windowPoint`: the nearest divider per orientation
    /// (pointer distance to the actual divider line, z-order breaking ties)
    /// plus the topmost hit for legacy single-axis precedence.
    static func dividerHits(
        at windowPoint: NSPoint,
        in regions: [PortalSplitDividerRegion],
        checkLiveness: Bool = true
    ) -> PortalDividerHits {
        var vertical: [(candidate: PortalDividerHits.Candidate, distance: CGFloat, order: Int)] = []
        var horizontal: [(candidate: PortalDividerHits.Candidate, distance: CGFloat, order: Int)] = []
        var first: PortalSplitDividerRegion?
        for (order, region) in regions.reversed().enumerated() {
            if checkLiveness, !region.isLive { continue }
            // The wide unclipped zone is a superset of the single-axis band;
            // one containment test gates candidacy for both.
            guard region.intersectionHitRectInWindow.contains(windowPoint) else { continue }
            // Applies to the cursor path too (which skips the structural
            // liveness check): a parked keepAllAlive divider must neither
            // advertise a resize/four-way cursor nor join a drag pair. The
            // alpha walk runs only for regions whose zone contains the point.
            guard region.isInteractable else { continue }
            let hitRect = region.hitRectInWindow
            let inBand = !hitRect.isNull && hitRect.contains(windowPoint)
            if inBand, first == nil { first = region }
            let distance = region.isVertical
                ? abs(windowPoint.x - region.rectInWindow.midX)
                : abs(windowPoint.y - region.rectInWindow.midY)
            let candidate = PortalDividerHits.Candidate(region: region, isInSingleAxisBand: inBand)
            if region.isVertical {
                vertical.append((candidate, distance, order))
            } else {
                horizontal.append((candidate, distance, order))
            }
        }
        // Nearest divider line first; z-order (topmost first) breaks ties.
        let byProximity: ((candidate: PortalDividerHits.Candidate, distance: CGFloat, order: Int),
                          (candidate: PortalDividerHits.Candidate, distance: CGFloat, order: Int)) -> Bool = {
            ($0.distance, $0.order) < ($1.distance, $1.order)
        }
        return PortalDividerHits(
            verticalCandidates: vertical.sorted(by: byProximity).map(\.candidate),
            horizontalCandidates: horizontal.sorted(by: byProximity).map(\.candidate),
            first: first
        )
    }

    static func dividerIntersection(
        at windowPoint: NSPoint,
        in regions: [PortalSplitDividerRegion],
        checkLiveness: Bool = true
    ) -> PortalDividerIntersection? {
        dividerHits(at: windowPoint, in: regions, checkLiveness: checkLiveness).intersection
    }

    /// Cursor-rect plan for a host view: single-axis band rects with the
    /// corner zones cut out, plus the corner zones themselves for the
    /// four-way cursor. Without the cut, a band's AppKit cursor rect keeps
    /// asserting a single-axis arrow inside the corner and the pointer
    /// flickers between it and the four-way cursor. All rects are in window
    /// coordinates; hosts convert, clip, and register them.
    static func cursorRectPlan(
        for regions: [PortalSplitDividerRegion]
    ) -> (bands: [(rect: NSRect, isVertical: Bool)], corners: [NSRect]) {
        // Cached keepAllAlive content remains structurally live while parked
        // at opacity zero. Match dividerHits' interaction filter so invisible
        // splits cannot register cursors or cut holes in visible bands.
        let interactableRegions = regions.filter(\.isInteractable)
        var corners: [NSRect] = []
        let verticals = interactableRegions.filter { $0.isVertical && !$0.isInHostedContent }
        let horizontals = interactableRegions.filter { !$0.isVertical && !$0.isInHostedContent }
        for vertical in verticals {
            for horizontal in horizontals where areNested(vertical, horizontal) {
                let corner = vertical.intersectionHitRectInWindow
                    .intersection(horizontal.intersectionHitRectInWindow)
                if !corner.isNull, corner.width > 0, corner.height > 0 {
                    corners.append(corner)
                }
            }
        }
        var bands: [(rect: NSRect, isVertical: Bool)] = []
        for region in interactableRegions {
            let band = region.hitRectInWindow
            guard !band.isNull, band.width > 0, band.height > 0 else { continue }
            for segment in subtractingAlongAxis(corners, from: band, isVertical: region.isVertical) {
                bands.append((segment, region.isVertical))
            }
        }
        return (bands, corners)
    }

    /// Splits `band` along its long axis around each intersecting hole. The
    /// corner zones are wider than the band's short axis, so subtraction
    /// reduces to 1-D range splitting.
    private static func subtractingAlongAxis(
        _ holes: [NSRect],
        from band: NSRect,
        isVertical: Bool
    ) -> [NSRect] {
        var ranges: [(lo: CGFloat, hi: CGFloat)] =
            isVertical ? [(band.minY, band.maxY)] : [(band.minX, band.maxX)]
        for hole in holes where hole.intersects(band) {
            let holeLo = isVertical ? hole.minY : hole.minX
            let holeHi = isVertical ? hole.maxY : hole.maxX
            var next: [(lo: CGFloat, hi: CGFloat)] = []
            for range in ranges {
                if holeHi <= range.lo || holeLo >= range.hi {
                    next.append(range)
                    continue
                }
                if holeLo > range.lo { next.append((range.lo, holeLo)) }
                if holeHi < range.hi { next.append((holeHi, range.hi)) }
            }
            ranges = next
        }
        return ranges.filter { $0.hi - $0.lo > 0.5 }.map { range in
            isVertical
                ? NSRect(x: band.minX, y: range.lo, width: band.width, height: range.hi - range.lo)
                : NSRect(x: range.lo, y: band.minY, width: range.hi - range.lo, height: band.height)
        }
    }

    /// True when one region's split view is nested inside the other's tree,
    /// i.e. the two dividers can meet at a real pane corner.
    static func areNested(_ first: PortalSplitDividerRegion, _ second: PortalSplitDividerRegion) -> Bool {
        guard let firstSplit = first.splitView, let secondSplit = second.splitView else { return false }
        return firstSplit.isDescendant(of: secondSplit) || secondSplit.isDescendant(of: firstSplit)
    }

    fileprivate static func uniqueRegions(_ regions: [PortalSplitDividerRegion]) -> [PortalSplitDividerRegion] {
        var seen = Set<String>()
        return regions.filter { region in
            guard let splitView = region.splitView else { return false }
            let key = "\(ObjectIdentifier(splitView))-\(region.dividerIndex)"
            return seen.insert(key).inserted
        }
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
        if splitView.isVertical {
            return NSRect(
                x: dividerRect.midX - Self.dividerHitExpansion,
                y: splitView.bounds.minY,
                width: Self.dividerHitExpansion * 2,
                height: splitView.bounds.height
            )
        }
        return NSRect(
            x: splitView.bounds.minX,
            y: dividerRect.midY - Self.dividerHitExpansion,
            width: splitView.bounds.width,
            height: Self.dividerHitExpansion * 2
        )
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
