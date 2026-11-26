import AppKit
import CmuxNextDesign

/// DEV and NIGHTLY (the Debug menu): how wide a tab grows in a roomy bar (Leo 2026-11-24: "do we never expand out tab
/// widths? ... why half of the space taken up by blank!?"). Every row is the real strip with three tabs, whatever the
/// playground's tab count: the tabs grow to fill the bar up to the row's max width, and the room past that stays empty
/// at the trailing end. The shipped row is `Metrics.tabMaxWidth`; the others only change this row's metrics.
struct TabMaxWidthPlaygroundVariants {
    private let fixture = TabBarPlaygroundFixture()
    private static let tabCount = 3

    var all: [TabBarPlaygroundVariant] {
        let shipped = Metrics.tabMaxWidth.rounded()
        return [
            variant(shipped, shipped: true),
            variant((shipped * 0.75).rounded()),
            variant((shipped * 1.5).rounded()),
        ]
    }

    private func variant(_ maxWidth: CGFloat, shipped: Bool = false) -> TabBarPlaygroundVariant {
        let fixture = fixture
        return TabBarPlaygroundVariant(name: Strings.playgroundTabMaxWidth(maxWidth), isShipped: shipped) { _ in
            TabBarPlaygroundBar(strip: fixture.strip(count: Self.tabCount, adjust: shipped ? nil : { metrics in
                metrics.maxTabWidth = maxWidth
                metrics.minActiveTabWidth = min(metrics.minActiveTabWidth, maxWidth)
                metrics.minInactiveTabWidth = min(metrics.minInactiveTabWidth, maxWidth)
            }))
        }
    }
}
