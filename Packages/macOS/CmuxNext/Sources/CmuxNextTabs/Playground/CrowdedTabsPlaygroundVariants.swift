import AppKit
import CmuxNextDesign

/// DEV and NIGHTLY (the Debug menu): how a crowded tab shows its title (Lawrence msg 19596, 26 tabs: "all here is … which is
/// not very helpful"). Every row is the real strip at the playground's tab count, with its own metrics.
struct CrowdedTabsPlaygroundVariants {
    private let fixture = TabBarPlaygroundFixture()

    var all: [TabBarPlaygroundVariant] {
        [
            variant(String(localized: "tabs.playground.crowded.shipped", defaultValue: "Favicon, faded title start, then scroll (74 pt)", bundle: .module),
                    shipped: true) { _ in },
            variant(String(localized: "tabs.playground.crowded.faviconClose", defaultValue: "Favicon and close width (50 pt), two faded characters", bundle: .module)) {
                $0.minInactiveTabWidth = $0.faviconCloseWidth
                $0.minActiveTabWidth = max($0.minActiveTabWidth - TabStripMetrics.crowdedTitleRoom, $0.faviconCloseWidth)
            },
            variant(String(localized: "tabs.playground.crowded.iconOnly", defaultValue: "Chrome: icon only, centered (32 pt)", bundle: .module)) {
                $0.minInactiveTabWidth = 32
                $0.minActiveTabWidth = max(56, $0.faviconCloseWidth)
            },
            variant(String(localized: "tabs.playground.crowded.wider", defaultValue: "Wider: favicon and about eight characters (96 pt)", bundle: .module)) {
                $0.minInactiveTabWidth = 96
                $0.minActiveTabWidth = 96
            },
            variant(String(localized: "tabs.playground.crowded.scroll", defaultValue: "Scrolling tabs: full width, scroll early (Tab Overflow: Scroll)", bundle: .module)) {
                $0.minInactiveTabWidth = ($0.maxTabWidth * 0.7).rounded()
                $0.minActiveTabWidth = $0.minInactiveTabWidth
            },
            variant(String(localized: "tabs.playground.crowded.shortFade", defaultValue: "74 pt with a short fade (8 pt)", bundle: .module)) {
                $0.titleFadeWidth = 8
            },
            variant(String(localized: "tabs.playground.crowded.noFragments", defaultValue: "74 pt, no title under 30 pt: icon only", bundle: .module)) {
                $0.titleMinVisibleWidth = 30
            },
            TabBarPlaygroundVariant(name: String(localized: "tabs.playground.crowded.compact", defaultValue: "Compact tabs: one fixed width", bundle: .module)) { count in
                TabBarPlaygroundBar(strip: fixture.strip(count: count, style: .compact))
            },
        ]
    }

    private func variant(_ name: String, shipped: Bool = false, adjust: @escaping (inout TabStripMetrics) -> Void) -> TabBarPlaygroundVariant {
        let fixture = fixture
        return TabBarPlaygroundVariant(name: name, isShipped: shipped) { count in
            TabBarPlaygroundBar(strip: fixture.strip(count: count, adjust: shipped ? nil : adjust))
        }
    }
}
