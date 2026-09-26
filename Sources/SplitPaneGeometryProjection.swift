import Bonsplit
import CoreGraphics

/// Projects where a pane's terminal content sits after bonsplit splits the
/// pane, before SwiftUI and AppKit realize the new layout.
///
/// bonsplit mutates its tree synchronously, but the split view that gives the
/// two panes real frames is created by a later SwiftUI update, and the
/// terminal's portal anchor arrives with it. Until then a hosted terminal view
/// keeps its pre-split frame. This projection reproduces the divider placement
/// `SplitContainerView.Coordinator` performs (`available = total − divider`,
/// pane minimums, `dividerPositionRange`, imposed extents) so the workspace can
/// move hosted views in the same transaction as the tree update. It is a
/// bounded approximation of AppKit's eventual layout, never a replacement: the
/// anchor's real geometry takes over as soon as the new host binds.
///
/// All rectangles are window points with the origin at the bottom-left, so a
/// pane's tab bar occupies the strip just above its content (`maxY` side).
struct SplitPaneGeometryProjection {
    /// bonsplit appearance values that shape a split's layout.
    struct Chrome: Equatable {
        var tabBarHeight: CGFloat
        var dividerThickness: CGFloat
        var minimumPaneWidth: CGFloat
        var minimumPaneHeight: CGFloat
        var dividerPositionRange: ClosedRange<CGFloat>

        init(
            tabBarHeight: CGFloat,
            dividerThickness: CGFloat,
            minimumPaneWidth: CGFloat,
            minimumPaneHeight: CGFloat,
            dividerPositionRange: ClosedRange<CGFloat>
        ) {
            self.tabBarHeight = tabBarHeight
            self.dividerThickness = dividerThickness
            self.minimumPaneWidth = minimumPaneWidth
            self.minimumPaneHeight = minimumPaneHeight
            self.dividerPositionRange = dividerPositionRange
        }

        init(configuration: BonsplitConfiguration) {
            self.init(
                tabBarHeight: configuration.appearance.tabBarHeight,
                dividerThickness: configuration.appearance.dividerThickness,
                minimumPaneWidth: configuration.appearance.minimumPaneWidth,
                minimumPaneHeight: configuration.appearance.minimumPaneHeight,
                dividerPositionRange: configuration.dividerPositionRange
            )
        }
    }

    struct Request {
        var orientation: SplitOrientation
        /// Whether the source pane is the split's first child (left or top).
        var sourceIsFirst: Bool
        /// The split's normalized divider position (first child's share).
        var dividerPosition: CGFloat
        /// An exact first-child extent imposed on the split, in points.
        var imposedFirstExtent: CGFloat?
        /// The source terminal's content frame before the split.
        var sourceContentFrame: CGRect
        /// Whether a tab bar sat above `sourceContentFrame` before the split.
        var baseShowsTabBar: Bool
        /// Whether the source pane shows a tab bar after the split.
        var sourceShowsTabBar: Bool
        /// Whether the new pane shows a tab bar.
        var newPaneShowsTabBar: Bool
    }

    struct Result: Equatable {
        var sourceContentFrame: CGRect
        var newPaneContentFrame: CGRect
    }

    /// Mirrors `TabBarMetrics.resolvedDividerThickness` in bonsplit.
    private static let dividerThicknessRange: ClosedRange<CGFloat> = 0...12

    static func project(_ request: Request, chrome: Chrome) -> Result? {
        let content = request.sourceContentFrame
        guard isFinite(content), content.width > 0, content.height > 0 else { return nil }
        let tabBarHeight = max(0, chrome.tabBarHeight)
        let baseTabBar = request.baseShowsTabBar ? tabBarHeight : 0
        // The pane container the new split view replaces: the content plus the
        // tab strip above it.
        let container = CGRect(
            x: content.minX,
            y: content.minY,
            width: content.width,
            height: content.height + baseTabBar
        )
        let thickness = resolvedDividerThickness(chrome.dividerThickness)
        let isHorizontal = request.orientation == .horizontal
        let total = isHorizontal ? container.width : container.height
        let available = max(total - thickness, 0)
        guard available > 0 else { return nil }

        let requestedMinimum = max(isHorizontal ? chrome.minimumPaneWidth : chrome.minimumPaneHeight, 1)
        let effectiveMinimum = min(requestedMinimum, available / 2)
        let minimumNormalized = min(0.5, effectiveMinimum / available)
        var lower = max(minimumNormalized, chrome.dividerPositionRange.lowerBound)
        var upper = min(1 - minimumNormalized, chrome.dividerPositionRange.upperBound)
        if lower > upper {
            let midpoint = min(
                max(0.5, chrome.dividerPositionRange.lowerBound),
                chrome.dividerPositionRange.upperBound
            )
            lower = midpoint
            upper = midpoint
        }
        let requestedFirstExtent = request.imposedFirstExtent ?? available * request.dividerPosition
        guard requestedFirstExtent.isFinite else { return nil }
        let firstExtent = min(max(requestedFirstExtent, available * lower), available * upper)
        let secondExtent = available - firstExtent

        let first: CGRect
        let second: CGRect
        if isHorizontal {
            first = CGRect(x: container.minX, y: container.minY, width: firstExtent, height: container.height)
            second = CGRect(
                x: container.minX + firstExtent + thickness,
                y: container.minY,
                width: secondExtent,
                height: container.height
            )
        } else {
            // The first child is the top pane, which is the higher `y` in
            // bottom-left window coordinates.
            first = CGRect(
                x: container.minX,
                y: container.maxY - firstExtent,
                width: container.width,
                height: firstExtent
            )
            second = CGRect(x: container.minX, y: container.minY, width: container.width, height: secondExtent)
        }
        let sourceContainer = request.sourceIsFirst ? first : second
        let newContainer = request.sourceIsFirst ? second : first
        return Result(
            sourceContentFrame: contentFrame(
                in: sourceContainer,
                tabBarHeight: request.sourceShowsTabBar ? tabBarHeight : 0
            ),
            newPaneContentFrame: contentFrame(
                in: newContainer,
                tabBarHeight: request.newPaneShowsTabBar ? tabBarHeight : 0
            )
        )
    }

    private static func contentFrame(in container: CGRect, tabBarHeight: CGFloat) -> CGRect {
        CGRect(
            x: container.minX,
            y: container.minY,
            width: max(0, container.width),
            height: max(0, container.height - tabBarHeight)
        )
    }

    private static func resolvedDividerThickness(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 1 }
        return min(max(value, dividerThicknessRange.lowerBound), dividerThicknessRange.upperBound)
    }

    private static func isFinite(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite && rect.size.width.isFinite && rect.size.height.isFinite
    }
}
