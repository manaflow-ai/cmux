public import AppKit

/// Discovers the best hosted Web Inspector divider pairing within a browser
/// window portal slot, and produces that divider's hit-test rectangle.
///
/// The finder carries the divider hit-test `hitExpansion` (the half-width the
/// hit rectangle is widened by on each side). `candidate(in:)` walks the slot's
/// visible descendants for hosted inspector views, climbs each toward the slot
/// looking for a sibling page view that overlaps it vertically and sits cleanly
/// to one side, and returns the highest-scoring pairing. The walk reads only
/// `NSView`/`NSRect` geometry plus the package's hosted-inspector candidate
/// predicates (`isVisibleHostedInspectorCandidate`,
/// `isVisibleHostedInspectorSiblingCandidate`, `isCmuxWebInspectorObject`) and
/// `HostedInspectorDockSide`, so it holds no app or window state.
@MainActor
public struct HostedInspectorDividerFinder {
    /// Half-width the divider hit rectangle is expanded by on each side in
    /// `hitRect(for:)`.
    public let hitExpansion: CGFloat

    /// Create a finder that widens divider hit rectangles by `hitExpansion` on
    /// each side.
    public init(hitExpansion: CGFloat) {
        self.hitExpansion = hitExpansion
    }

    /// The best hosted inspector divider pairing within `slot`, or `nil` when no
    /// inspector/page pair is present.
    @MainActor
    public func candidate(in slot: NSView) -> HostedInspectorDividerHit? {
        let inspectorCandidates = slot.visibleDescendants
            .filter { $0.isVisibleHostedInspectorCandidate && $0.isCmuxWebInspectorObject }
            .sorted { lhs, rhs in
                let lhsFrame = slot.convert(lhs.bounds, from: lhs)
                let rhsFrame = slot.convert(rhs.bounds, from: rhs)
                return lhsFrame.minX < rhsFrame.minX
            }

        var bestHit: HostedInspectorDividerHit?
        var bestScore = -CGFloat.greatestFiniteMagnitude

        for inspectorCandidate in inspectorCandidates {
            guard let candidate = candidate(in: slot, startingAt: inspectorCandidate) else {
                continue
            }
            let score = Self.candidateScore(candidate)
            if score > bestScore {
                bestScore = score
                bestHit = candidate
            }
        }

        return bestHit
    }

    @MainActor
    private func candidate(
        in slot: NSView,
        startingAt inspectorLeaf: NSView
    ) -> HostedInspectorDividerHit? {
        var current: NSView? = inspectorLeaf
        var bestHit: HostedInspectorDividerHit?

        while let inspectorView = current, inspectorView !== slot {
            guard let containerView = inspectorView.superview else { break }

            let pageCandidates = containerView.subviews.compactMap { candidate -> (view: NSView, dockSide: HostedInspectorDockSide)? in
                guard candidate.isVisibleHostedInspectorSiblingCandidate else { return nil }
                guard candidate !== inspectorView else { return nil }
                guard candidate.frame.verticalOverlap(with: inspectorView.frame) > 8 else {
                    return nil
                }
                guard let dockSide = HostedInspectorDockSide.resolve(
                    pageFrame: candidate.frame,
                    inspectorFrame: inspectorView.frame
                ) else {
                    return nil
                }
                return (view: candidate, dockSide: dockSide)
            }

            if let pageCandidate = pageCandidates.max(by: {
                Self.pageCandidateScore($0.view, inspectorView: inspectorView)
                    < Self.pageCandidateScore($1.view, inspectorView: inspectorView)
            }) {
                bestHit = HostedInspectorDividerHit(
                    slotView: slot,
                    containerView: containerView,
                    pageView: pageCandidate.view,
                    inspectorView: inspectorView,
                    dockSide: pageCandidate.dockSide
                )
            }

            current = containerView
        }

        return bestHit
    }

    /// The divider hit-test rectangle for `hit`, centered on the divider and
    /// widened by `hitExpansion` on each side.
    @MainActor
    public func hitRect(for hit: HostedInspectorDividerHit) -> NSRect {
        let slotBounds = hit.slotView.bounds
        let pageFrame = hit.slotView.convert(hit.pageView.bounds, from: hit.pageView)
        let inspectorFrame = hit.slotView.convert(hit.inspectorView.bounds, from: hit.inspectorView)
        return hit.dockSide.dividerHitRect(
            in: slotBounds,
            pageFrame: pageFrame,
            inspectorFrame: inspectorFrame,
            expansion: hitExpansion
        )
    }

    @MainActor
    private static func candidateScore(_ hit: HostedInspectorDividerHit) -> CGFloat {
        let pageFrame = hit.slotView.convert(hit.pageView.bounds, from: hit.pageView)
        let inspectorFrame = hit.slotView.convert(hit.inspectorView.bounds, from: hit.inspectorView)
        let overlap = pageFrame.verticalOverlap(with: inspectorFrame)
        let coverageWidth = max(pageFrame.maxX, inspectorFrame.maxX) - min(pageFrame.minX, inspectorFrame.minX)
        return (overlap * 1_000) + coverageWidth + pageFrame.width
    }

    @MainActor
    private static func pageCandidateScore(_ pageView: NSView, inspectorView: NSView) -> CGFloat {
        let overlap = pageView.frame.verticalOverlap(with: inspectorView.frame)
        let coverageWidth = max(pageView.frame.maxX, inspectorView.frame.maxX) - min(pageView.frame.minX, inspectorView.frame.minX)
        return (overlap * 1_000) + coverageWidth + pageView.frame.width
    }
}
