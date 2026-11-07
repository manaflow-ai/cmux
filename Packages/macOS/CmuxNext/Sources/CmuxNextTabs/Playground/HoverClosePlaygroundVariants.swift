import AppKit
import CmuxNextDesign

/// DEV and NIGHTLY (the Debug menu): how a hovered tab's x takes its status's slot (Leo 2026-11-05: "the button
/// replaces the spinner on the top when you hover over it, like just like the sidebar with the workspaces"). Every
/// row is the real strip with busy, waiting and unread tabs; the second tab starts hovered, and hovering any other
/// tab shows its own swap.
struct HoverClosePlaygroundVariants {
    private let fixture = TabBarPlaygroundFixture()

    var all: [TabBarPlaygroundVariant] {
        [
            variant(String(localized: "tabs.playground.hoverClose.crossFade", defaultValue: "The x takes the status's slot, cross-fading with it",
                           bundle: .module), .crossFade, shipped: true),
            variant(String(localized: "tabs.playground.hoverClose.instant", defaultValue: "The status gives way at once, as a sidebar row",
                           bundle: .module), .instant),
            variant(String(localized: "tabs.playground.hoverClose.disc", defaultValue: "Cross-fade, the x on its hover fill", bundle: .module), .disc),
            variant(String(localized: "tabs.playground.hoverClose.beside", defaultValue: "Before: the x beside the status", bundle: .module), .beside),
        ]
    }

    private func variant(_ name: String, _ swap: TabHoverCloseSwap, shipped: Bool = false) -> TabBarPlaygroundVariant {
        let fixture = fixture
        return TabBarPlaygroundVariant(name: name, isShipped: shipped) { count in
            let model = fixture.model(count: count)
            // Busy, waiting, the selected tab busy and unread, then unread: each kind of status the x stands in for.
            model.tabs = model.tabs.enumerated().map { index, tab in
                var tab = tab
                switch index % 4 {
                case 0: tab.isBusy = true
                case 1: tab.status = .needsInput
                case 2: tab.isBusy = true; tab.isUnread = true
                default: tab.isUnread = index % 8 == 3
                }
                return tab
            }
            let strip = TabStripView(model: model)
            var metrics = TabStripMetrics.standard
            metrics.hoverCloseSwap = swap
            strip.customMetrics = metrics
            return HoverClosePlaygroundRow(bar: TabBarPlaygroundBar(strip: strip), hovered: model.tabs[min(1, model.tabs.count - 1)].id)
        }
    }
}

/// A Hover Close row: the bar with one tab shown hovered until the pointer moves over the strip, so a still capture
/// shows the swap.
final class HoverClosePlaygroundRow: NSView {
    private let bar: TabBarPlaygroundBar
    private var hovered: TabID?

    init(bar: TabBarPlaygroundBar, hovered: TabID) {
        self.bar = bar
        self.hovered = hovered
        super.init(frame: bar.frame)
        addSubview(bar)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        bar.frame = bounds
        bar.layoutSubtreeIfNeeded()
        // Once the strip has its cells: the first layout can come before the strip reads its model.
        if let id = hovered, bar.strip.cells[id] != nil {
            bar.strip.setHovered(id)
            hovered = nil
        }
    }
}
