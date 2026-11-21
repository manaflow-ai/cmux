import AppKit

/// DEV and NIGHTLY (the Debug menu): how a busy tab with unread output draws (Leo 2026-10-22, ask-a8b97f1201: "the
/// tab unread + simultaneous ongoing thing feels weird idk if there is a way to combine + the spacing is off"). Every
/// row is the real strip with busy and unread, busy, unread and quiet tabs, one look per row.
struct BusyUnreadPlaygroundVariants {
    private let fixture = TabBarPlaygroundFixture()

    var all: [TabBarPlaygroundVariant] {
        [
            variant(String(localized: "tabs.playground.busyUnread.spinner", defaultValue: "One mark: the spinner, then the dot in its place",
                           bundle: .module), .spinner, shipped: true),
            variant(String(localized: "tabs.playground.busyUnread.tinted", defaultValue: "One mark: the spinner in the unread blue",
                           bundle: .module), .tintedSpinner),
            variant(String(localized: "tabs.playground.busyUnread.dotInRing", defaultValue: "One mark: the spinner ringing the unread dot",
                           bundle: .module), .dotInRing),
            variant(String(localized: "tabs.playground.busyUnread.pair", defaultValue: "Before: the dot and the spinner side by side",
                           bundle: .module), .pair),
        ]
    }

    private func variant(_ name: String, _ look: TabBusyUnreadMark, shipped: Bool = false) -> TabBarPlaygroundVariant {
        let fixture = fixture
        return TabBarPlaygroundVariant(name: name, isShipped: shipped) { count in
            let model = fixture.model(count: count)
            // Busy with unread output, busy, unread, then quiet.
            model.tabs = model.tabs.enumerated().map { index, tab in
                var tab = tab
                switch index % 4 {
                case 0: tab.isBusy = true; tab.isUnread = true
                case 1: tab.isBusy = true
                case 2: tab.isUnread = true
                default: break
                }
                return tab
            }
            let strip = TabStripView(model: model)
            var metrics = TabStripMetrics.standard
            metrics.busyUnreadMark = look
            strip.customMetrics = metrics
            return TabBarPlaygroundBar(strip: strip)
        }
    }
}
