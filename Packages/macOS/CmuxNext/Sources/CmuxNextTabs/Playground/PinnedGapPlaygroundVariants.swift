import AppKit
import CmuxNextDesign

/// DEV and NIGHTLY (the Debug menu): the space between the pinned tabs and the other tabs (Lawrence msg 20243: the pinned
/// doc and image tabs sat against the first normal tab, spaced unlike any other pair). Every row is
/// the real strip with two pinned tabs, the first normal tab selected, at the playground's tab count.
struct PinnedGapPlaygroundVariants {
    private let fixture = TabBarPlaygroundFixture()

    var all: [TabBarPlaygroundVariant] {
        [
            variant(String(localized: "tabs.playground.pinned.shipped", defaultValue: "Tab gap, divider, tab gap", bundle: .module),
                    shipped: true) { _ in },
            variant(String(localized: "tabs.playground.pinned.before", defaultValue: "Before: 4 pt extra, no divider", bundle: .module)) {
                $0.pinnedGroupGap = Metrics.space2
                $0.showsPinnedDivider = false
            },
            variant(String(localized: "tabs.playground.pinned.uniform", defaultValue: "Tab gap only: no divider, no extra space", bundle: .module)) {
                $0.pinnedGroupGap = 0
                $0.showsPinnedDivider = false
            },
            variant(String(localized: "tabs.playground.pinned.wide", defaultValue: "Wider: 6 pt, divider, 6 pt", bundle: .module)) {
                $0.pinnedGroupGap = 2 * Metrics.space3 + 1 - 2 * $0.tabBackgroundInset
            },
            variant(String(localized: "tabs.playground.pinned.tall", defaultValue: "Tab gap, tall divider (tab height less 8 pt)", bundle: .module)) {
                $0.separatorHeight = max(0, $0.tabHeight - 2 * Metrics.space2)
            },
            variant(String(localized: "tabs.playground.pinned.strong", defaultValue: "Tab gap, stronger divider", bundle: .module)) {
                $0.separatorOpacity = min(1, $0.separatorOpacity * 2)
            },
            variant(String(localized: "tabs.playground.pinned.safari", defaultValue: "Safari: wide space, no divider (12 pt)", bundle: .module)) {
                $0.pinnedGroupGap = 3 * Metrics.space2 - 2 * $0.tabBackgroundInset
                $0.showsPinnedDivider = false
            },
        ]
    }

    private func variant(_ name: String, shipped: Bool = false, adjust: @escaping (inout TabStripMetrics) -> Void) -> TabBarPlaygroundVariant {
        let fixture = fixture
        return TabBarPlaygroundVariant(name: name, isShipped: shipped) { count in
            TabBarPlaygroundBar(strip: fixture.strip(count: count, pinned: 2, adjust: shipped ? nil : adjust))
        }
    }
}
