import AppKit

/// DEV and NIGHTLY (the Debug menu): where a tab's trailing spinner or unread dot sits beside its title (Leo
/// 2026-10-22, ask-a8b97f1201: "the tab unread + simultaneous ongoing thing feels weird idk if there is a way to
/// combine + the spacing is off"). Every row is the real strip with busy, busy and unread, unread and quiet tabs,
/// one placement per row.
struct StatusSpacingPlaygroundVariants {
    private let fixture = TabBarPlaygroundFixture()

    var all: [TabBarPlaygroundVariant] {
        [
            variant(String(localized: "tabs.playground.statusSpacing.mirrorIcon",
                           defaultValue: "The mark mirrors the icon's inset",
                           bundle: .localizedModule), .mirrorIcon, shipped: true),
            variant(String(localized: "tabs.playground.statusSpacing.mirrorAll",
                           defaultValue: "The mark and the hovered close button both mirror the icon",
                           bundle: .localizedModule), .mirrorAll),
            variant(String(localized: "tabs.playground.statusSpacing.closeSlot",
                           defaultValue: "Before: the mark in the close button's slot, nearer the end",
                           bundle: .localizedModule), .closeSlot),
        ]
    }

    private func variant(_ name: String, _ placement: TabStatusMarkPlacement, shipped: Bool = false) -> TabBarPlaygroundVariant {
        let fixture = fixture
        return TabBarPlaygroundVariant(name: name, isShipped: shipped) { count in
            let model = fixture.model(count: count)
            // Busy, busy with unread output, unread, then quiet.
            model.tabs = model.tabs.enumerated().map { index, tab in
                var tab = tab
                switch index % 4 {
                case 0: tab.isBusy = true
                case 1: tab.isBusy = true; tab.isUnread = true
                case 2: tab.isUnread = true
                default: break
                }
                return tab
            }
            let strip = TabStripView(model: model)
            var metrics = TabStripMetrics.standard
            metrics.statusMarkPlacement = placement
            strip.customMetrics = metrics
            return TabBarPlaygroundBar(strip: strip)
        }
    }
}
