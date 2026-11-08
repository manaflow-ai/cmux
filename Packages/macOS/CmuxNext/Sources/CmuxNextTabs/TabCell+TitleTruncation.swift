import AppKit
import CoreText

extension TabCell {
    /// How a title `textWidth` wide draws in a visible area `visibleWidth` wide: never truncated.
    ///
    /// Chrome's tab (Lawrence 2026-11-07, cmux beside Chrome: "Austin's…(7 days)"): no "…" anywhere. The title starts
    /// at its first character, runs to the tab's trailing end and fades out there (`TitleFade`). Middle truncation
    /// (#28625, kept for a distinguishing suffix such as "Helper 1", "Helper 2") put a "…" inside the title; the hover
    /// card and the tab's tooltip still show the whole title. nil: the line is clipped, never truncated.
    static func titleTruncation(textWidth: CGFloat, visibleWidth: CGFloat) -> CTLineTruncationType? { nil }
}
