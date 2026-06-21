public import CoreGraphics
public import SwiftUI

/// The rounded-rectangle background chrome behind a workspace row.
///
/// Fills a 6pt-corner rectangle, strokes an optional active border, and draws an
/// optional leading accent rail. The caller resolves the fill, border, and rail
/// colors and the border width from the active/indicator state and passes them
/// in as values, so this package view carries no app-target color dependency.
/// Intended for use inside the row's `.background { }` so it sizes to the row.
public struct SidebarWorkspaceRowBackground: View {
    let fillColor: Color
    let borderColor: Color
    let borderLineWidth: CGFloat
    let showsLeadingRail: Bool
    let railColor: Color

    /// Creates the row background chrome.
    /// - Parameters:
    ///   - fillColor: Fill color for the rounded rectangle.
    ///   - borderColor: Stroke color for the active border.
    ///   - borderLineWidth: Stroke width for the active border (0 to hide).
    ///   - showsLeadingRail: Whether to draw the leading accent rail.
    ///   - railColor: Fill color for the leading rail capsule.
    public init(
        fillColor: Color,
        borderColor: Color,
        borderLineWidth: CGFloat,
        showsLeadingRail: Bool,
        railColor: Color
    ) {
        self.fillColor = fillColor
        self.borderColor = borderColor
        self.borderLineWidth = borderLineWidth
        self.showsLeadingRail = showsLeadingRail
        self.railColor = railColor
    }

    public var body: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(fillColor)
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(borderColor, lineWidth: borderLineWidth)
            }
            .overlay(alignment: .leading) {
                if showsLeadingRail {
                    Capsule(style: .continuous)
                        .fill(railColor)
                        .frame(width: 3)
                        .padding(.leading, 4)
                        .padding(.vertical, 5)
                        .offset(x: -1)
                }
            }
    }
}
