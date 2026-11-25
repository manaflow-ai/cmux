import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextTerminal
import Testing

/// Lawrence 2026-11-20 (msg 42498): "it is possible for me to hover close, and for the width to
/// change, but after i mousedown and drag, it fails to scroll". On a terminal the pointer over the
/// scroller's strip widened the knob along the whole strip, but a press took the scroller only on the
/// knob itself: on the track above or below it the press went to the terminal. Every pixel column
/// from the terminal's trailing edge in, on the knob and on the track: the knob is wide exactly where
/// a press lands on the scroller.
@MainActor @Suite struct TerminalScrollerGrabZoneTests {
    static let hostFrame = CGRect(x: 0, y: 0, width: 600, height: 400)
    /// 900 rows, the viewport near the top of the scrollback (the knob near the top, track below).
    static let scrolledBack = TerminalScrollbar(totalRows: 900, offsetRows: 40, visibleRows: 24)

    @Test func theKnobWidensExactlyWhereAPressLandsOnTheScroller() throws {
        let host = TerminalHostView()
        host.frame = Self.hostFrame
        host.layoutSubtreeIfNeeded()
        host.showScrollbar(TerminalScrollbar(totalRows: 900, offsetRows: 876, visibleRows: 24))
        host.showScrollbar(Self.scrolledBack) // a move through the scrollback builds the scroller
        let scrollView = try #require(TerminalScrollerLazyTests.scrollViews(in: host).first)
        host.layoutSubtreeIfNeeded()
        let thin = try #require(scrollView.verticalScroller as? ThinScroller)
        let knob = thin.convert(thin.rect(for: .knob), to: host)
        let rows: [(String, CGFloat)] = [("knob", knob.midY), ("track", knob.midY > 200 ? 60 : 340)]
        var mismatches: [String] = []
        var widened: [String: [Int]] = [:]
        for (name, y) in rows {
            for column in 0..<Int(Self.hostFrame.width) {
                let point = CGPoint(x: Self.hostFrame.maxX - CGFloat(column) - 0.5, y: y)
                // The scroller's tracking area covers its own scroll view (the strip).
                thin.pointerMoved(to: nil)
                if scrollView.frame.contains(point) { thin.pointerMoved(to: scrollView.convert(point, from: host)) }
                let wide = thin.isKnobExpanded
                let grabs = host.hitTest(point) === thin
                if wide { widened[name, default: []].append(column) }
                if wide != grabs { mismatches.append("\(name) column \(column): wide \(wide), press lands on the scroller \(grabs)") }
            }
        }
        #expect(mismatches.isEmpty, "\(mismatches)")
        let knobColumns = widened["knob"] ?? []
        #expect(!knobColumns.isEmpty)
        #expect(knobColumns == Array(0..<knobColumns.count))
        #expect(widened["track"] == knobColumns)
    }
}
