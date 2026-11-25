import AppKit
import CmuxNextDesign

/// DEV and NIGHTLY (the Debug menu): candidates for the tab bar's new-tab control (Lawrence msg 19605: "plus with down
/// chevron is not good at all i dont like. make more variations"). The first rows are the real
/// strip's own options; the rest put a candidate control (``TabBarPlaygroundNewTabControl``) where
/// the + sits today, before the pane's ⋮. The shipped control stays until one is picked.
struct NewTabControlPlaygroundVariants {
    private let fixture = TabBarPlaygroundFixture()

    var all: [TabBarPlaygroundVariant] {
        let fixture = fixture
        var variants = [
            TabBarPlaygroundVariant(name: String(localized: "tabs.playground.newTab.shipped", defaultValue: "+ and a separate ⌄ chooser", bundle: .module),
                                    isShipped: true) { count in
                let strip = fixture.strip(count: count)
                strip.showsNewTabMenuButton = true
                return TabBarPlaygroundBar(strip: strip)
            },
            TabBarPlaygroundVariant(name: String(localized: "tabs.playground.newTab.chrome", defaultValue: "Chrome and Helium: a plain + after the last tab, kinds on right-click or hold", bundle: .module)) { count in
                TabBarPlaygroundBar(strip: fixture.strip(count: count))
            },
            TabBarPlaygroundVariant(name: String(localized: "tabs.playground.newTab.caret", defaultValue: "+ with a caret inside: a click opens the kinds", bundle: .module)) { count in
                let strip = fixture.strip(count: count)
                strip.opensNewTabMenuOnPress = true
                return TabBarPlaygroundBar(strip: strip)
            },
            TabBarPlaygroundVariant(name: String(localized: "tabs.playground.newTab.inMore", defaultValue: "No +: New Tab and the kinds in the ⋮ menu (⌘T stays)", bundle: .module)) { count in
                TabBarPlaygroundBar(strip: fixture.strip(count: count, showsNewTabButton: false))
            },
        ]
        let candidates: [(TabBarPlaygroundNewTabControl.Style, String)] = [
            (.plusOnly, String(localized: "tabs.playground.newTab.plusOnly", defaultValue: "A plain + at the trailing end, kinds on right-click or hold", bundle: .module)),
            (.plusOpensMenu, String(localized: "tabs.playground.newTab.plusMenu", defaultValue: "One + that opens a small menu of kinds", bundle: .module)),
            (.chevronOnHover, String(localized: "tabs.playground.newTab.hoverChevron", defaultValue: "+ with a ⌄ that shows only on hover", bundle: .module)),
            (.cornerBadge, String(localized: "tabs.playground.newTab.badge", defaultValue: "+ with a tiny ⌄ badge in its corner", bundle: .module)),
            (.segmented, String(localized: "tabs.playground.newTab.segmented", defaultValue: "+ and ⌄ as one split capsule", bundle: .module)),
            (.chevronFirst, String(localized: "tabs.playground.newTab.chevronFirst", defaultValue: "⌄ before the +", bundle: .module)),
            (.filledPlus, String(localized: "tabs.playground.newTab.filled", defaultValue: "Safari: + in a filled rounded square", bundle: .module)),
            (.labeled, String(localized: "tabs.playground.newTab.labeled", defaultValue: "+ New Tab, with its label", bundle: .module)),
            (.largePlus, String(localized: "tabs.playground.newTab.large", defaultValue: "A larger +, the toolbar's button size", bundle: .module)),
        ]
        variants += candidates.map { style, name in
            TabBarPlaygroundVariant(name: name) { count in
                let strip = fixture.strip(count: count, showsNewTabButton: false)
                let control = TabBarPlaygroundNewTabControl(style: style, model: strip.model)
                return TabBarPlaygroundBar(strip: strip, accessory: control, accessoryWidth: control.preferredWidth)
            }
        }
        return variants
    }
}
