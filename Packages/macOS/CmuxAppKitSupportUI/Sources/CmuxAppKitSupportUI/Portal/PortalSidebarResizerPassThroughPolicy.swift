public import CoreGraphics
public import CmuxSidebar

/// Decides whether a portal-hosted terminal host view should let a pointer fall
/// through to the SwiftUI sidebar resizer handle instead of consuming it.
///
/// The sidebar resizer handles (leading workspace sidebar, trailing file
/// explorer) are implemented in SwiftUI. When terminals are portal-hosted, the
/// AppKit host view can sit above those handles and steal hover/mouse events, so
/// the host hit-tests each pointer against the inferred divider positions and
/// passes through when the point lands in a resizer band.
///
/// The leading-divider position cannot be read directly, so it is inferred from
/// the leftmost visible hosted-surface edge and cached across calls. The cache
/// carries a small miss counter so a stale divider position is dropped after a
/// few layout-churn frames rather than continuing to steal pointer routing. That
/// cache is the only mutable state, held here so the host view forwards inputs
/// instead of owning the inference. The live AppKit lookups (which subviews are
/// visible hosted surfaces, their frames, the right-sidebar-dock flag, and the
/// host bounds) stay in the view and feed `shouldPassThrough` as value inputs;
/// nothing here touches AppKit, SwiftUI, or window state. The band geometry is
/// supplied by the constructor-injected ``CmuxSidebar/SidebarResizerBandPolicy``
/// so production passes the app's shared resizer band values and tests can pin
/// them.
public struct PortalSidebarResizerPassThroughPolicy: Sendable {
    /// A visible portal-hosted terminal surface, reduced to the geometry the
    /// pass-through inference needs.
    public struct HostedSurfaceFrame: Sendable {
        /// The surface's frame in the host view's coordinate space.
        public let frame: CGRect

        /// Whether the surface is the right-sidebar dock surface (excluded from
        /// the trailing-divider edge so the dock surface itself is not treated
        /// as content).
        public let isRightSidebarDockSurface: Bool

        /// Creates a hosted-surface input.
        /// - Parameters:
        ///   - frame: The surface frame in host-view space.
        ///   - isRightSidebarDockSurface: Whether the surface is the right
        ///     sidebar dock surface.
        public init(frame: CGRect, isRightSidebarDockSurface: Bool) {
            self.frame = frame
            self.isRightSidebarDockSurface = isRightSidebarDockSurface
        }
    }

    /// Below this leading edge, content is treated as flush to the host's leading
    /// edge (sidebar effectively hidden).
    private static let sidebarLeadingEdgeEpsilon: CGFloat = 1

    /// Minimum visible leading-content width, and the minimum trailing gap, for a
    /// divider band to be considered.
    private static let minimumVisibleLeadingContentWidth: CGFloat = 24

    private let bandPolicy: SidebarResizerBandPolicy
    private var cachedSidebarDividerX: CGFloat?
    private var sidebarDividerMissCount = 0

    /// Creates a pass-through policy.
    /// - Parameter bandPolicy: The resizer hit-band geometry used to test whether
    ///   a point lands in a leading or trailing divider band.
    public init(bandPolicy: SidebarResizerBandPolicy) {
        self.bandPolicy = bandPolicy
    }

    /// Whether the host should pass `point` through to the SwiftUI sidebar
    /// resizer instead of consuming it.
    ///
    /// Mutates the cached leading-divider inference as a side effect.
    /// - Parameters:
    ///   - point: The pointer location in the host view's coordinate space.
    ///   - bounds: The host view's bounds.
    ///   - hostedSurfaces: The visible portal-hosted surfaces, in subview order.
    /// - Returns: `true` if the point lands in a leading or trailing resizer band.
    public mutating func shouldPassThrough(
        at point: CGPoint,
        bounds: CGRect,
        hostedSurfaces: [HostedSurfaceFrame]
    ) -> Bool {
        if shouldPassThroughToTrailing(at: point, bounds: bounds, hostedSurfaces: hostedSurfaces) {
            return true
        }

        // If content is flush to the leading edge, sidebar is effectively hidden.
        // In that state, treating any internal split edge as a sidebar divider
        // steals split-divider cursor/drag behavior.
        let hasLeadingContent = hostedSurfaces.contains {
            $0.frame.minX <= Self.sidebarLeadingEdgeEpsilon
                && $0.frame.maxX > Self.minimumVisibleLeadingContentWidth
        }
        if hasLeadingContent {
            if cachedSidebarDividerX != nil {
                sidebarDividerMissCount += 1
                if sidebarDividerMissCount >= 2 {
                    cachedSidebarDividerX = nil
                    sidebarDividerMissCount = 0
                }
            }
            return false
        }

        // Ignore transient 0-origin hosts while layouts churn (e.g. workspace
        // creation/switching). They can temporarily report minX=0 and would
        // otherwise clear divider pass-through, causing hover flicker.
        let dividerCandidates = hostedSurfaces
            .map(\.frame.minX)
            .filter { $0 > Self.sidebarLeadingEdgeEpsilon }
        if let leftMostEdge = dividerCandidates.min() {
            cachedSidebarDividerX = leftMostEdge
            sidebarDividerMissCount = 0
        } else if cachedSidebarDividerX != nil {
            // Keep cache briefly for layout churn, but clear if we miss repeatedly
            // so stale divider positions don't steal pointer routing.
            sidebarDividerMissCount += 1
            if sidebarDividerMissCount >= 4 {
                cachedSidebarDividerX = nil
                sidebarDividerMissCount = 0
            }
        }

        guard let dividerX = cachedSidebarDividerX else {
            return false
        }

        return bandPolicy.hitRange(for: .leading, dividerX: dividerX).contains(point.x)
    }

    private func shouldPassThroughToTrailing(
        at point: CGPoint,
        bounds: CGRect,
        hostedSurfaces: [HostedSurfaceFrame]
    ) -> Bool {
        let contentHostedViews = hostedSurfaces.filter { !$0.isRightSidebarDockSurface }
        guard let rightMostEdge = contentHostedViews.map(\.frame.maxX).max() else { return false }
        let trailingGap = bounds.maxX - rightMostEdge
        guard trailingGap > Self.minimumVisibleLeadingContentWidth else { return false }
        return bandPolicy.hitRange(for: .trailing, dividerX: rightMostEdge).contains(point.x)
    }
}
