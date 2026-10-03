import CoreGraphics
import Foundation

/// Carries the mode bar's full-label width out of its layout, so the right
/// sidebar's minimum width fits every tab's name plus the trailing controls.
/// The layout writes it while measuring; the change is delivered on the next
/// main-queue turn, never during a view update.
@MainActor
final class RightSidebarModeBarWidthReport {
    var onChange: ((CGFloat) -> Void)?
    private var reported: CGFloat = 0

    /// Space the bar needs beside its tabs: the gaps before the open-as-pane
    /// and close buttons, both buttons, and the bar's own leading and
    /// trailing padding.
    static var trailingReserve: CGFloat {
        RightSidebarChromeMetrics.headerLeadingPadding
            + RightSidebarChromeMetrics.headerTrailingPadding
            + 3 * RightSidebarChromeMetrics.headerControlSpacing
            + 2 * RightSidebarChromeMetrics.headerControlSize
    }

    /// Notes the tabs' width with every label in full, gaps included.
    func note(tabsWidth: CGFloat) {
        let width = (tabsWidth + Self.trailingReserve).rounded(.up)
        guard abs(width - reported) > 0.5 else { return }
        reported = width
        DispatchQueue.main.async { [weak self] in self?.onChange?(width) }
    }
}
