import CoreGraphics
import Foundation
import os

/// Carries the mode bar's needed width out of its layout, so the right
/// sidebar's minimum width fits the selected tab's name, the other tabs as
/// icons, and the trailing controls.
/// The layout writes it while measuring; the change is delivered on the next
/// main-queue turn, never during a view update.
///
/// SwiftUI may measure a `Layout` off the main thread (seen on macOS 15), so
/// `note(tabsWidth:)` is callable from any thread: it dedupes under a lock and
/// only touches `onChange` on the main queue.
@MainActor
final class RightSidebarModeBarWidthReport {
    var onChange: ((CGFloat) -> Void)?
    private nonisolated let reportedTabsWidth = OSAllocatedUnfairLock<CGFloat?>(initialState: nil)

    /// Space the bar needs beside its tabs: the gaps before the open-as-pane
    /// and close buttons, both buttons, and the bar's own leading and
    /// trailing padding.
    static var trailingReserve: CGFloat {
        RightSidebarChromeMetrics.headerLeadingPadding
            + RightSidebarChromeMetrics.headerTrailingPadding
            + 3 * RightSidebarChromeMetrics.headerControlSpacing
            + 2 * RightSidebarChromeMetrics.headerControlSize
    }

    /// Notes the tabs' width (one full label, the rest icons), gaps included.
    nonisolated func note(tabsWidth: CGFloat) {
        let changed = reportedTabsWidth.withLock { reported -> Bool in
            if let reported, abs(tabsWidth - reported) <= 0.5 { return false }
            reported = tabsWidth
            return true
        }
        guard changed else { return }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.onChange?((tabsWidth + Self.trailingReserve).rounded(.up))
            }
        }
    }
}
