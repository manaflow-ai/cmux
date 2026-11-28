#if canImport(CoreGraphics)
import CoreGraphics
#else
import Foundation
#endif

/// The grid's top edge under the title bar (hq docs/design/ios-tab-overview-vocabulary.md §8).
///
/// Leo's screenshot (2026-11-22) showed card titles ("…tricting AI agent…", "Explain O1") legible
/// behind the workspace title: the edge faded from its middle, half way up the header's text.
/// Decision: nothing is legible behind the header. The edge is opaque down to the bottom of the
/// top controls (the header's text sits inside them) and fades only below, to the first row.
public enum OverviewTitleEdgeStyle: String, Sendable, CaseIterable {
    /// Opaque to the controls' bottom, then a short fade to the first row (the default).
    case opaqueThenFade
    /// Gallery: opaque to the first row, no fade.
    case hard
    /// Gallery: opaque to the controls' bottom, then a long progressive blur over the first row.
    case progressiveBlur
    /// Gallery: the system's soft scroll edge effect instead of our own layer.
    case system

    /// DEBUG gallery switch: `CMUX_TABS_TITLE_EDGE=hard|progressiveBlur|system`. Release builds
    /// always draw the default.
    static func current(environment: [String: String]) -> Self {
        #if DEBUG
        if let raw = environment["CMUX_TABS_TITLE_EDGE"], let style = Self(rawValue: raw) { return style }
        #endif
        return .opaqueThenFade
    }
}

/// Where the edge is opaque and where it ends, in points from the screen's top.
struct OverviewTitleEdge: Equatable, Sendable {
    /// Bottom of the top controls: the header's title and subtitle end above it.
    var opaqueBottom: CGFloat
    /// Where the edge is fully clear.
    var height: CGFloat

    /// The controls sit 4 pt under the safe area, one control tall; the first row starts at
    /// `OverviewLayout.pinnedTop` (safe area + 60).
    init(style: OverviewTitleEdgeStyle, safeTop: CGFloat, control: CGFloat) {
        let controlsBottom = safeTop + 4 + control
        let firstRow = safeTop + 12 + control
        switch style {
        case .opaqueThenFade, .system:
            opaqueBottom = controlsBottom
            height = firstRow
        case .hard:
            opaqueBottom = firstRow
            height = firstRow
        case .progressiveBlur:
            opaqueBottom = controlsBottom
            height = firstRow + 28
        }
    }

    /// The opaque share of the edge's height, as a gradient stop.
    var opaqueStop: CGFloat { height > 0 ? min(1, opaqueBottom / height) : 1 }
}
