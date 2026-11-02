import SwiftUI

enum SidebarWorkspaceGroupingMetrics {
    /// Leading inset applied to workspace rows that visually nest under a group header.
    static let memberIndent: CGFloat = 12

    /// Indent-guide line width, in points. Not scaled by the sidebar font; the
    /// guide is a hairline rather than a glyph that grows with the text.
    static let guideWidth: CGFloat = 2

    /// Smallest member indent, in points, that still leaves room for the indent
    /// guide. The guide is not drawn below this; the upstream configurable
    /// member indent can go as low as 0.
    static let guideMinimumIndent: CGFloat = 6

    /// Run-ending guide bottom inset at the default sidebar font size: how far a
    /// run's last segment stops short of the row's bottom edge instead of
    /// overlapping the inter-row gap (see ``guideEndRunBottomInset(fontScale:)``).
    static let baseGuideEndRunBottomInset: CGFloat = 4

    /// x-position of the indent guide's center within a member row: the row's
    /// outer padding plus half the member indent, so the line sits in the
    /// middle of the gutter the indent opens up. Fixed, because neither the
    /// outer padding nor the member indent scales with the sidebar font.
    static var guideCenterX: CGFloat {
        SidebarWorkspaceListMetrics.rowOuterHorizontalPadding + memberIndent / 2
    }

    /// Whether the indent guide is drawn at the current member indent: `false`
    /// when the indent is narrower than ``guideMinimumIndent``.
    static var showsGuide: Bool { memberIndent >= guideMinimumIndent }

    /// The run-ending guide bottom inset scaled by the sidebar font scale.
    /// - Parameter fontScale: The scale from ``SidebarTabItemFontScale/scale(for:)``;
    ///   `1.0` at the default sidebar font size.
    static func guideEndRunBottomInset(fontScale: CGFloat) -> CGFloat {
        baseGuideEndRunBottomInset * fontScale
    }
}
