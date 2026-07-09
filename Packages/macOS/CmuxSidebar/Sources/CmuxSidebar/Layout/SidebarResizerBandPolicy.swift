public import CoreGraphics

/// Pure geometry for the sidebar/right-explorer resizer hit bands.
///
/// Each divider has a hit band that is slightly wider than the visible divider
/// so the resize cursor and drag are easy to grab. The band straddles the
/// divider: it starts a little before the divider (more on the sidebar side,
/// less on the content side so edge text selection still wins) and runs for a
/// fixed total width. The two hit-width constants and the divider positions are
/// supplied by the caller; this type holds the math.
///
/// This is the geometry half of the sidebar resizer cluster, extracted from the
/// app's `ContentView.dividerBandContains` as a faithful byte-identical lift. It
/// holds the fixed hit-width constants as instance state (constructor-injected so
/// the production composition root supplies the app's
/// `SidebarResizeInteraction` values and tests can pin them) and computes whether
/// a content-space point lands in either active divider band. The live pointer
/// sampling, window/content lookups, and cursor state stay in the view and feed
/// these inputs; nothing about the geometry touches AppKit, SwiftUI, or window
/// state.
public struct SidebarResizerBandPolicy: Sendable, Equatable {
    /// Hit width consumed on the sidebar side of the leading divider.
    public let sidebarSideHitWidth: CGFloat

    /// Hit width consumed on the content side of a divider.
    public let contentSideHitWidth: CGFloat

    /// Total hit-band width straddling a divider
    /// (``sidebarSideHitWidth`` + ``contentSideHitWidth``).
    public var totalHitWidth: CGFloat {
        sidebarSideHitWidth + contentSideHitWidth
    }

    /// Which side of a divider the resizer band lives on.
    public enum Edge: Sendable, Equatable {
        /// The leading (left workspace sidebar) divider.
        case leading
        /// The trailing (right file explorer) divider.
        case trailing
    }

    /// Creates a resizer-band policy from the fixed divider hit-width constants.
    /// - Parameters:
    ///   - sidebarSideHitWidth: Hit width on the sidebar side of the leading
    ///     divider.
    ///   - contentSideHitWidth: Hit width on the content side of a divider.
    public init(sidebarSideHitWidth: CGFloat, contentSideHitWidth: CGFloat) {
        self.sidebarSideHitWidth = sidebarSideHitWidth
        self.contentSideHitWidth = contentSideHitWidth
    }

    private func hitWidthBeforeDivider(for edge: Edge) -> CGFloat {
        switch edge {
        case .leading:
            return sidebarSideHitWidth
        case .trailing:
            return contentSideHitWidth
        }
    }

    /// The leading x of the hit band for `edge` at `dividerX`.
    /// - Parameters:
    ///   - edge: The divider side.
    ///   - dividerX: The x position of the divider in content space.
    /// - Returns: The band's leading x.
    public func handleX(for edge: Edge, dividerX: CGFloat) -> CGFloat {
        dividerX - hitWidthBeforeDivider(for: edge)
    }

    /// The closed x-range of the hit band for `edge` at `dividerX`.
    /// - Parameters:
    ///   - edge: The divider side.
    ///   - dividerX: The x position of the divider in content space.
    /// - Returns: The band's x-range, ``totalHitWidth`` wide.
    public func hitRange(for edge: Edge, dividerX: CGFloat) -> ClosedRange<CGFloat> {
        let minX = handleX(for: edge, dividerX: dividerX)
        return minX...(minX + totalHitWidth)
    }

    /// Whether a content-space point lands in either active divider band.
    ///
    /// The point must be within the vertical content bounds and inside one of the
    /// visible dividers' hit ranges. The leading band uses `leftDividerX`; the
    /// trailing band uses `rightDividerX`. A divider whose visibility flag is
    /// `false` contributes no band.
    /// - Parameters:
    ///   - point: The pointer location in content space.
    ///   - contentBounds: The content view's bounds (supplies the y-range).
    ///   - leftDividerVisible: Whether the leading sidebar divider is shown.
    ///   - leftDividerX: The leading divider's x position in content space.
    ///   - rightDividerVisible: Whether the trailing explorer divider is shown.
    ///   - rightDividerX: The trailing divider's x position in content space.
    /// - Returns: `true` if the point is in an active band.
    public func bandContains(
        point: CGPoint,
        contentBounds: CGRect,
        leftDividerVisible: Bool,
        leftDividerX: CGFloat,
        rightDividerVisible: Bool,
        rightDividerX: CGFloat
    ) -> Bool {
        guard point.y >= contentBounds.minY, point.y <= contentBounds.maxY else { return false }
        if leftDividerVisible,
           hitRange(for: .leading, dividerX: leftDividerX).contains(point.x) {
            return true
        }

        return rightDividerVisible &&
            hitRange(for: .trailing, dividerX: rightDividerX).contains(point.x)
    }
}
