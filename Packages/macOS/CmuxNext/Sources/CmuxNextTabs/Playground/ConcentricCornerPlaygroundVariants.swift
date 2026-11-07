import AppKit
import CmuxNextDesign

/// DEV and NIGHTLY (the Debug menu): the Corner Radius page (Lawrence 2026-11-04): one outer radius
/// (`layout.paneCornerRadius`) for panes and tabs, one padding (`layout.cornerPadding`), every nested
/// corner the outer less the padding (``ConcentricCorners``). Each row is a pane card at one pair of
/// values with the real strip in it; the first row is the default the app ships.
struct ConcentricCornerPlaygroundVariants {
    private let fixture = TabBarPlaygroundFixture()

    /// The (outer radius, padding) pairs shown, the shipped default first.
    static let pairs: [(outer: CGFloat, padding: CGFloat)] = [(10, 2), (6, 2), (14, 2), (14, 6), (12, 4), (16, 8), (8, 0), (0, 2)]

    var all: [TabBarPlaygroundVariant] {
        Self.pairs.enumerated().map { index, pair in
            let corners = ConcentricCorners(outer: pair.outer, padding: pair.padding)
            let fixture = fixture
            return TabBarPlaygroundVariant(name: Strings.playgroundCornerName(outer: pair.outer, padding: pair.padding), isShipped: index == 0) { count in
                let strip = fixture.strip(count: min(count, 4)) { metrics in
                    metrics.cornerRadius = corners.radius(fitting: CGSize(width: metrics.tabHeight, height: metrics.tabHeight), radius: corners.inner)
                    metrics.stripHorizontalPadding = 0
                    metrics.stripTopOutset = 0
                }
                return ConcentricCornerPlaygroundRow(corners: corners, strip: strip)
            }
        }
    }
}
