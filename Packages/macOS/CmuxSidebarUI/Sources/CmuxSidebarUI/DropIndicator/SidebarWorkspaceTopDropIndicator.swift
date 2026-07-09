public import SwiftUI

/// Thin accent-colored bar drawn at the top edge of a workspace row to show
/// that a drag will drop above it.
///
/// The accent color is injected (`accent`) rather than read from an app-target
/// appearance helper so the view stays in the sidebar UI package with no
/// reach-up. The app passes its `cmuxAccentColor()`; the bar's geometry
/// (2pt height, 8pt horizontal inset, half-row-spacing upward offset for
/// non-first rows) is unchanged from the original ContentView definition.
public struct SidebarWorkspaceTopDropIndicator: View {
    private let isVisible: Bool
    private let isFirstRow: Bool
    private let rowSpacing: CGFloat
    private let accent: Color
    private let isBottomEdge: Bool
    private let leadingInset: CGFloat

    /// - Parameters:
    ///   - isVisible: Whether the drop indicator is shown for this row.
    ///   - isFirstRow: First row draws flush; later rows offset up by half the
    ///     row spacing so the bar sits in the gap above the row.
    ///   - rowSpacing: The sidebar's inter-row spacing, used for the offset.
    ///   - accent: The accent color used to fill the bar.
    ///   - isBottomEdge: When `true`, the bar sits in the gap *below* the row
    ///     (offset down by half the row spacing) for a bottom-edge drop.
    ///   - leadingInset: Extra leading inset (e.g. group-scoped indentation).
    public init(
        isVisible: Bool,
        isFirstRow: Bool,
        rowSpacing: CGFloat,
        accent: Color,
        isBottomEdge: Bool = false,
        leadingInset: CGFloat = 0
    ) {
        self.isVisible = isVisible
        self.isFirstRow = isFirstRow
        self.rowSpacing = rowSpacing
        self.accent = accent
        self.isBottomEdge = isBottomEdge
        self.leadingInset = leadingInset
    }

    public var body: some View {
        if isVisible {
            Rectangle()
                .fill(accent)
                .frame(height: 2)
                .padding(.leading, Self.horizontalPadding + max(leadingInset, 0))
                .padding(.trailing, Self.horizontalPadding)
                .offset(y: indicatorOffset)
        }
    }

    private static let horizontalPadding: CGFloat = 8

    private var indicatorOffset: CGFloat {
        isBottomEdge ? rowSpacing / 2 : (isFirstRow ? 0 : -(rowSpacing / 2))
    }
}
