public import CoreGraphics

/// Resolves the tool sidebar divider from portal-hosted content in one linear pass.
public struct ToolSidebarDividerRouting: Sendable {
    /// The minimum content width required on either side of a valid divider.
    public let minimumVisibleContentWidth: CGFloat

    /// Creates a divider routing policy.
    ///
    /// - Parameter minimumVisibleContentWidth: The minimum visible content width on either side of a divider candidate.
    public init(minimumVisibleContentWidth: CGFloat) {
        self.minimumVisibleContentWidth = minimumVisibleContentWidth
    }

    /// Returns the divider between a leading tool sidebar and workspace content.
    ///
    /// The workspace's leading edge is authoritative. During transient layout churn,
    /// the trailing edge of Dock content provides a stable fallback.
    ///
    /// - Parameters:
    ///   - portals: Visible portal-hosted values to inspect.
    ///   - bounds: The containing portal bounds.
    ///   - frame: A projection from a portal value to its frame in `bounds` coordinates.
    ///   - isDock: A projection that identifies values hosted inside the Dock tool.
    /// - Returns: The divider coordinate, or `nil` when no valid candidate exists.
    public func leftDividerX<Portal>(
        in portals: [Portal],
        bounds: CGRect,
        frame: (Portal) -> CGRect,
        isDock: (Portal) -> Bool
    ) -> CGFloat? {
        let minimumDividerX = bounds.minX + minimumVisibleContentWidth
        let maximumDividerX = bounds.maxX - minimumVisibleContentWidth
        guard maximumDividerX > minimumDividerX else { return nil }

        var contentLeadingEdge: CGFloat?
        var dockTrailingEdge: CGFloat?
        for portal in portals {
            let portalFrame = frame(portal)
            if isDock(portal) {
                let candidate = portalFrame.maxX
                guard candidate > minimumDividerX, candidate < maximumDividerX else { continue }
                dockTrailingEdge = max(dockTrailingEdge ?? candidate, candidate)
            } else {
                let candidate = portalFrame.minX
                guard candidate > minimumDividerX, candidate < maximumDividerX else { continue }
                contentLeadingEdge = min(contentLeadingEdge ?? candidate, candidate)
            }
        }

        return contentLeadingEdge ?? dockTrailingEdge
    }
}
