import CoreGraphics

/// Geometry shared by the Cloud outline's document and row content.
///
/// AppKit owns the outline document width, while SwiftUI owns the contents of
/// each hosted cell. Keeping the viewport rule here makes both sides agree on
/// how much width is available without coupling a row to a particular sidebar
/// size.
struct CloudTreeLayoutMetrics: Equatable, Sendable {
    /// The horizontal inset used by the former Cloud setup entry and by row
    /// accessories at the trailing edge.
    let referenceInset: CGFloat

    /// Creates Cloud tree geometry for the given content inset.
    init(referenceInset: CGFloat = 12) {
        self.referenceInset = max(0, referenceInset)
    }

    /// The document follows the visible scroll viewport so rows receive the
    /// full sidebar width and the tree never grows a hidden horizontal gutter.
    func documentWidth(viewportWidth: CGFloat) -> CGFloat {
        max(0, viewportWidth)
    }

    /// Keeps an empty outline scrollable while preserving a taller row document.
    func documentHeight(viewportHeight: CGFloat, existingHeight: CGFloat) -> CGFloat {
        max(0, viewportHeight, existingHeight)
    }

    /// Width left for a title after stable trailing controls and both insets.
    /// Titles receive all remaining space and therefore truncate only after
    /// metadata, notification dots, and hover actions have been reserved.
    func titleWidth(
        rowWidth: CGFloat,
        leadingContentWidth: CGFloat,
        trailingContentWidth: CGFloat
    ) -> CGFloat {
        max(0, rowWidth - leadingContentWidth - trailingContentWidth - referenceInset)
    }
}
