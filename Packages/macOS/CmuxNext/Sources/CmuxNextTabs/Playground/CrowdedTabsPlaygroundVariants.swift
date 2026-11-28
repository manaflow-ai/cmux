import AppKit
import CmuxNextDesign

/// DEV and NIGHTLY (the Debug menu): how a crowded tab shows its title (Lawrence msg 19596, 26 tabs: "all here is … which is
/// not very helpful"). Every row is the real strip at the playground's tab count, with its own metrics.
struct CrowdedTabsPlaygroundVariants {
    private let fixture = TabBarPlaygroundFixture()

    var all: [TabBarPlaygroundVariant] {
        [
            variant(String(localized: "tabs.playground.crowded.shipped", defaultValue: "Favicon, faded title start, then scroll (74 pt)", bundle: .localizedModule),
                    shipped: true) { _ in },
            variant(String(localized: "tabs.playground.crowded.faviconClose", defaultValue: "Favicon and close width (50 pt), two faded characters", bundle: .localizedModule)) {
                $0.minInactiveTabWidth = $0.faviconCloseWidth
                $0.minActiveTabWidth = max($0.minActiveTabWidth - TabStripMetrics.crowdedTitleRoom, $0.faviconCloseWidth)
            },
            variant(String(localized: "tabs.playground.crowded.iconOnly", defaultValue: "Chrome: icon only, centered (32 pt)", bundle: .localizedModule)) {
                $0.minInactiveTabWidth = 32
                $0.minActiveTabWidth = max(56, $0.faviconCloseWidth)
            },
            variant(String(localized: "tabs.playground.crowded.wider", defaultValue: "Wider: favicon and about eight characters (96 pt)", bundle: .localizedModule)) {
                $0.minInactiveTabWidth = 96
                $0.minActiveTabWidth = 96
            },
            variant(String(localized: "tabs.playground.crowded.scroll", defaultValue: "Scrolling tabs: full width, scroll early (Tab Overflow: Scroll)", bundle: .localizedModule)) {
                $0.minInactiveTabWidth = ($0.maxTabWidth * 0.7).rounded()
                $0.minActiveTabWidth = $0.minInactiveTabWidth
            },
            variant(String(localized: "tabs.playground.crowded.shortFade", defaultValue: "74 pt with a short fade (8 pt)", bundle: .localizedModule)) {
                $0.titleFadeWidth = 8
            },
            variant(String(localized: "tabs.playground.crowded.noFragments", defaultValue: "74 pt, no title under 30 pt: icon only", bundle: .localizedModule)) {
                $0.titleMinVisibleWidth = 30
            },
            // Leo 2026-11-27: "ok why dont your tabs have any names/letters showing up? that intentional?" Crowded agent
            // tabs (a spinner and a machine badge on every other tab): what gives way so the title keeps its letters.
            agentVariant(String(localized: "tabs.playground.crowded.agentsOnIcon", defaultValue: "Agent tabs: marks move onto the icon, title keeps its letters (shipped)", bundle: .localizedModule)) { _ in },
            agentVariant(String(localized: "tabs.playground.crowded.agentsTrailing", defaultValue: "Agent tabs: marks keep their place, title hides (before)", bundle: .localizedModule)) {
                $0.crowdedMarks = .trailing
            },
            agentVariant(String(localized: "tabs.playground.crowded.agentsDropBadges", defaultValue: "Agent tabs: badges hide, status stays beside the title", bundle: .localizedModule)) {
                $0.crowdedMarks = .dropBadges
            },
            agentVariant(String(localized: "tabs.playground.crowded.agentsOneLetter", defaultValue: "Agent tabs: marks on the icon, a title down to its first letter", bundle: .localizedModule)) {
                $0.titleMinCharacters = 1.5
            },
            TabBarPlaygroundVariant(name: String(localized: "tabs.playground.crowded.compact", defaultValue: "Compact tabs: one fixed width", bundle: .localizedModule)) { count in
                TabBarPlaygroundBar(strip: fixture.strip(count: count, style: .compact))
            },
        ]
    }

    private func agentVariant(_ name: String, adjust: @escaping (inout TabStripMetrics) -> Void) -> TabBarPlaygroundVariant {
        let fixture = fixture
        return TabBarPlaygroundVariant(name: name) { count in
            TabBarPlaygroundBar(strip: fixture.strip(count: count, agentMarks: true, adjust: adjust))
        }
    }

    private func variant(_ name: String, shipped: Bool = false, adjust: @escaping (inout TabStripMetrics) -> Void) -> TabBarPlaygroundVariant {
        let fixture = fixture
        return TabBarPlaygroundVariant(name: name, isShipped: shipped) { count in
            TabBarPlaygroundBar(strip: fixture.strip(count: count, adjust: shipped ? nil : adjust))
        }
    }
}
