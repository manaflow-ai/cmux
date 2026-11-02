import AppKit
import Testing
@testable import MessagesLabHome

/// Cmd-= / Cmd-- on Home change the Chief chat's text size, not its bubble column
/// (https://github.com/manaflow-ai/cmux/issues/28978). The chat lays out at its pane's width over the zoom and draws
/// magnified, and Messages' column rule has a negative constant term, so the column on screen was
/// 0.654 x pane - 52 x zoom: zooming in narrowed it and zooming out widened it.
/// These read the pure rule with an explicit zoom ratio; `Metrics.columnZoom` (a process value) is not touched.
@Suite struct HomeZoomColumnTests {
    /// Agent Chat Zoom's range and step (AgentPaneZoomSetting), the Chief chat's widest column at its lowest.
    static let widest: CGFloat = 0.5
    static let zooms: [CGFloat] = stride(from: 0.5, through: 2.0001, by: 0.1).map { $0 }

    /// The column's width in window points for a `pane`-point chat at `zoom`.
    static func onScreen(pane: CGFloat, zoom: CGFloat) -> CGFloat {
        zoom * Metrics.column(width: pane / zoom, columnZoom: zoom / widest)
    }

    @Test(arguments: [320, 434, 520, 700, 1000, 1400] as [CGFloat])
    func everyZoomKeepsTheMostZoomedOutColumn(pane: CGFloat) {
        let widestColumn = Self.widest * Metrics.column(width: pane / Self.widest)
        for zoom in Self.zooms {
            #expect(abs(Self.onScreen(pane: pane, zoom: zoom) - widestColumn) < 0.1, "pane \(pane) zoom \(zoom)")
        }
    }

    /// Before: a 700 pt pane's column was 431.6 pt at zoom 0.5 and 373.4 pt at zoom 2.
    @Test func messagesOwnColumnNarrowedAsTheZoomGrew() {
        let before = { (zoom: CGFloat) in zoom * Metrics.column(width: 700 / zoom) }
        #expect(before(0.5) - before(2) > 50)
        #expect(abs(Self.onScreen(pane: 700, zoom: 2) - before(0.5)) < 0.1)
    }

    /// The default (zoom 1) column is the most zoomed-out one, wider than the one it had.
    @Test func theDefaultColumnIsTheMostZoomedOutOne() {
        let old = Metrics.column(width: 700)
        let now = Self.onScreen(pane: 700, zoom: 1)
        #expect(now > old + 20)
        #expect(abs(now - 0.5 * Metrics.column(width: 1400)) < 0.1)
    }

    /// Outside a zoomed chat (ratio 1) the column is Messages' own.
    @Test func ratioOneIsMessagesOwnColumn() {
        for width in [300, 434, 628, 900] as [CGFloat] {
            #expect(Metrics.column(width: width, columnZoom: 1) == Metrics.column(width: width))
        }
        #expect(Metrics.column(width: 628) == Fixture.maxTextWidth)
    }
}
