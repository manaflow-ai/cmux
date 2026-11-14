import CoreGraphics

/// One number of a browser pane's tab bar and omnibar that the Density Overlay Playground tunes per density
/// (``BrowserChromeTuning``). Each has a default in Helium's proportions at Default, Compact and Comfortable and
/// Chrome's sizes at Spacious (plans/cmux-next/helium-density/source-values.md).
public nonisolated enum BrowserChromeMetric: String, CaseIterable, Sendable {
    /// The tab pill's and the omnibar's height: the density's `browserRowHeight` token.
    case rowHeight
    /// The one gap above the pills, between them and the omnibar, and under the omnibar: `browserRowGap`.
    case rowGap
    /// The tab x's hover square.
    case closeSize
    /// The hover square's corner.
    case closeCorner
    /// The x's ink, square.
    case closeInk
    /// The hover square's distance from the pill's trailing edge.
    case closeTrailing
    /// The omnibar's page-info chip's distance from the bar's leading edge.
    case chipLeading
    /// Where the URL's text starts in the bar.
    case textOrigin

    /// The density token that holds the value, for the two the density presets declare.
    public var token: String? {
        switch self {
        case .rowHeight: "browserRowHeight"
        case .rowGap: "browserRowGap"
        default: nil
        }
    }

    /// The Debug Settings label (developer text, as every tunable's).
    var label: String {
        switch self {
        case .rowHeight: "Row height"
        case .rowGap: "Row gap"
        case .closeSize: "Close square"
        case .closeCorner: "Close corner"
        case .closeInk: "Close ink"
        case .closeTrailing: "Close to tab end"
        case .chipLeading: "Omnibar chip inset"
        case .textOrigin: "Omnibar text start"
        }
    }

    /// The Debug Settings help line, with the Helium value it defaults to at Default.
    var help: String {
        switch self {
        case .rowHeight: "Tab pill and omnibar height. Helium: 28."
        case .rowGap: "Gap above the tabs, between tabs and omnibar, and under the omnibar. Helium: 3."
        case .closeSize: "Side of the tab x's hover square. Helium: 14 on a 28 pt tab."
        case .closeCorner: "Corner of the x's hover square. Helium: 4."
        case .closeInk: "Side of the x's ink. Helium: 8."
        case .closeTrailing: "Hover square to the pill's trailing edge. Helium: 6."
        case .chipLeading: "Bar edge to the page-info chip. Helium: 2."
        case .textOrigin: "Bar edge to the URL's text. Helium: 31."
        }
    }

    /// The slider's range in points.
    var range: ClosedRange<Double> {
        switch self {
        case .rowHeight: 16...48
        case .rowGap: 0...12
        case .closeSize, .closeInk: 4...28
        case .closeCorner, .closeTrailing, .chipLeading: 0...16
        case .textOrigin: 10...60
        }
    }
}
