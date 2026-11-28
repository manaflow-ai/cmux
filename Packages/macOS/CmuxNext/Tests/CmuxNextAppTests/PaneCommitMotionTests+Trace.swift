import AppKit
@testable import CmuxNextLayout
import CmuxNextTestSupport
import QuartzCore
import Testing

/// `PaneCommitMotionTests`, what the motion's trace says of a pane that moves.
///
/// A move is animations on a pane host's layer: the view's frame has the end's value from the frame that shows the
/// act. The trace's sample (`ScreenContentView.motionSample`) gives each pane's frame, and after it, as the last 4
/// numbers of the pane's row, where the pane's layer is in that sample: the frame of the layer's presentation layer,
/// in window points with a top-left origin. A reader of a recording needs that rect to know which pixels are the
/// pane's in a frame of a move.
extension PaneCommitMotionTests {
    /// The numbers after the pane's name in each pane row of the trace's sample of `screen`, by pane: 0 to 3 what
    /// shows of the pane, 4 its alpha, 5 its place in the order, 6 to 9 its frame, 10 to 16 its content, and from
    /// 17 where its layer is in this sample.
    static func traceRows(of screen: ScreenContentView) throws -> [String: [Double]] {
        let sample = try #require(ScreenContentView.motionSample(screen), "the screen gives no trace sample")
        var rows: [String: [Double]] = [:]
        for case let row as [Any] in sample["panes"] ?? [] {
            guard let pane = row.first as? String else { continue }
            rows[pane] = row.dropFirst().map { number in (number as? Double) ?? (number as? Int).map { Double($0) } ?? Double.nan }
        }
        return rows
    }

    /// At rest each pane row of the trace's sample ends with 4 numbers that are the pane's frame: a layer with no
    /// move is where its view is.
    @Test func atRestAPaneRowOfTheTraceEndsWithThePanesFrame() throws {
        let harness = Commit.Harness(Commit.pair, focused: Commit.left, holds: false)
        defer { harness.window.closeAfterTest() }
        Self.movePanes(harness)
        Commit.rest(harness)
        CATransaction.flush()
        let screen = try #require(harness.screen)
        let rows = try Self.traceRows(of: screen)
        try #require(rows.count == 2, "SETUP: the trace's sample has \(rows.count) pane rows for the pair")
        for (pane, row) in rows {
            #expect(row.count == 21, "the row of \(pane) has \(row.count) numbers, not 17 and the 4 of its layer's place")
            guard row.count == 21 else { continue }
            #expect(Array(row[17...20]) == Array(row[0...3]), "at rest the row of \(pane) ends with \(row[17...20]); what shows of the pane is \(row[0...3])")
        }
    }

    /// A zoom moves its pane. In the frame that shows the zoom the pane's frame in its trace row is the end's. The
    /// row's last 4 numbers are where the pane's layer is: with a presentation layer (a host whose window has a
    /// committed layer tree) that is not the end rect, and it is inside the rect that the start and the end make;
    /// with none it is the layer's own frame. After the motion's end it is the end rect.
    @Test func inAMoveAPaneRowOfTheTraceEndsWithWhereThePanesLayerIs() throws {
        let alone = try Self.alone(zoomed: true)
        defer { alone.harness.window.closeAfterTest() }
        let layer = try #require(alone.host.layer, "SETUP: the pane that zooms has no layer")
        let move = Self.move(of: layer)
        try #require(move.moves && move.start != move.end, "SETUP: the zoom's pane has no move: \(move.start) to \(move.end)")
        CATransaction.flush()
        let presents = layer.presentation() != nil
        let row = try #require(Self.traceRows(of: alone.screen)[alone.host.pane.rawValue], "the trace's sample has no row for the pane that zooms")
        try #require(row.count == 21, "the row has \(row.count) numbers, not 17 and the 4 of its layer's place")
        let end = Array(row[0...3]), live = Array(row[17...20])
        print("TRACE PRESENTATION: the test host gives a presentation layer = \(presents); the row ends with \(live), the pane's frame is \(end)")
        if presents {
            let far = zip(live, end).contains { abs($0 - $1) > 1 }
            #expect(far, "in the zoom's move the row ends with \(live), which is the end rect \(end)")
            let all = alone.screen.convert(move.start.union(move.end), to: nil).insetBy(dx: -1, dy: -1)
            let low = (alone.screen.window?.frame.height ?? 0) - live[1] - live[3]
            let rect = CGRect(x: live[0], y: low, width: live[2], height: live[3])
            #expect(all.contains(rect), "in the zoom's move the row ends with the rect \(rect) (window points); the move is inside \(all)")
        } else {
            #expect(live == end, "with no presentation layer the row ends with \(live), not with the layer's frame \(end)")
        }

        _ = Self.toTheEnd(alone.harness, alone.screen)
        CATransaction.flush()
        let after = try #require(Self.traceRows(of: alone.screen)[alone.host.pane.rawValue], "the trace's sample has no row for the pane after the motion's end")
        try #require(after.count == 21, "after the end the row has \(after.count) numbers")
        #expect(Array(after[17...20]) == Array(after[0...3]), "after the motion's end the row ends with \(after[17...20]); the pane's frame is \(after[0...3])")
    }
}
