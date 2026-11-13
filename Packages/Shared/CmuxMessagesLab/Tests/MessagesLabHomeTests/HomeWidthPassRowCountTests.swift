#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
@testable import CmuxHomeCore
import Foundation
import Testing
@testable import MessagesLabHome

/// A pane resize with a long Home transcript (Lawrence, 2026-11-11: "when i resize panes ... all must have smooth
/// transition"): the rows one width step measures follow the rows near the viewport, not the loaded rows.
///
/// A width change measured the parts near the viewport exactly and estimated the others, but it still walked every
/// loaded row (`RowBuilder.rewidth`) and set every row in the model again (`TranscriptModel.set`: a key set, a
/// dictionary of the old rows and a new index over all of them). With 5000 loaded rows that walk was most of a frame,
/// so the Home could not follow its pane in a key resize and was held (`PaneKeyResizeHeld`, cmux#41105).
///
/// The transcripts here have 50 and 500 rows, not 5000: a Debug test bundle measures every message of a 5000-row
/// transcript two times for each drag, and one test then gives no result for more than the 180 s of the suite
/// watchdog on a Mac mini (step dffec0670251, 2026-11-13). The count of a width step shows the fault at 500 rows
/// as well as at 5000; the times of a 5000-row Home come from the films on a bench host.
///
/// The test drives the real Home view over a seeded Chief transcript (`HomeStore.debugSeed`, the film seed) and
/// counts the rows each width step handed to measuring (`MessagesWindowView.widthRowsVisited`, a count of the view). What a person sees is
/// checked too: every row on screen is at the transcript's width in every step, also after a scroll to the oldest row
/// right after the drag, and when the width rests every loaded row is exact at that width.
@MainActor @Suite(.serialized) struct HomeWidthPassRowCountTests {
    struct Drag {
        /// Rows handed to measuring, one entry per width step.
        var visited: [Int] = []
        /// Main-thread time of each width step (the pass, the layout and the Core Animation flush), ms.
        var ms: [Double] = []
        /// Rows on screen that were not at the transcript's width, summed over the steps.
        var shownAtOtherWidth = 0
        /// The same after a scroll to the oldest row, before the exact rows of the resting width are in.
        var shownAtOtherWidthAfterScroll = 0
        var loadedRows = 0
        /// Every loaded row was exact at the transcript's width once the width rested.
        var exactAtRest = false
    }

    /// Rows on screen (the cells the list holds) whose width is not the transcript's.
    static func shownAtOtherWidth(_ demo: MessagesWindowView) -> Int {
        demo.collection.visibleCells
            .compactMap { demo.collection.indexPath(for: $0) }
            .compactMap { demo.model.rows[checked: $0.item] }
            .filter { !$0.ghost && $0.spec.width != demo.bounds.width }
            .count
    }

    /// A seeded transcript of `rows` rows in a 700 x 900 pt Home at its newest row, then 30 width steps of 4 pt, one
    /// a frame (what a pane's key resize or a divider drag gives the Home), a scroll to the oldest row, and the rest.
    func drag(rows: Int) async throws -> Drag {
        let rig = try await HomeChatRig(history: 40, width: 700, height: 900)
        defer { rig.stop() }
        let seeded = await rig.store.debugSeed(HomeChatRig.conversation, rows: rows)
        #expect(seeded, "the store took a seed of \(rows) rows")
        let demo = try #require(rig.view.controller.demo)
        for _ in 0..<2_000 where demo.model.liveCount < rows {
            rig.frame()
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(demo.model.liveCount >= rows, "the Home shows the \(rows) seeded rows (it shows \(demo.model.liveCount))")
        // The rows at rest before the drag: exact at 700 pt (an estimated row waits for the off-main measure).
        for _ in 0..<20_000 where demo.model.rows.contains(where: { $0.spec.estimated }) {
            rig.frame()
            try await Task.sleep(for: .milliseconds(1))
        }

        var out = Drag()
        out.loadedRows = demo.model.liveCount
        var width: CGFloat = 700
        let measureCalls = demo.measureWindowCalls, measureStarts = demo.measureWindowStarts
        for _ in 0..<30 {
            width -= 4
            let visited = demo.widthRowsVisited, t0 = CACurrentMediaTime()
            rig.resize(width: width)
            out.ms.append((CACurrentMediaTime() - t0) * 1000)
            out.visited.append(demo.widthRowsVisited - visited)
            out.shownAtOtherWidth += Self.shownAtOtherWidth(demo)
        }
        // No assert: the count for the PR text. The loop above gives the main queue no turn, so a measure that started
        // cannot end in it: the calls are how often the rest signal fired in a drag with one width step a frame.
        print("HOMEWIDTHPASS rows \(rows) in the 30 steps the rest signal asked for the measure of every loaded message"
              + " \(demo.measureWindowCalls - measureCalls) times, the measure started \(demo.measureWindowStarts - measureStarts) times")
        // The person scrolls to the oldest row at once (no turn of the main queue since the last step, so the exact
        // rows of the resting width are not in): the rows that come on screen are at the transcript's width.
        demo.collection.contentOffset = CGPoint(x: demo.collection.contentOffset.x, y: demo.minOffset)
        demo.userScrolled()
        rig.frame()
        out.shownAtOtherWidthAfterScroll = Self.shownAtOtherWidth(demo)
        // The width rests: every loaded row is measured off main and the exact rows are installed.
        func exact() -> Bool { demo.model.rows.allSatisfy { $0.ghost || ($0.spec.width == demo.bounds.width && !$0.spec.estimated) } }
        for _ in 0..<20_000 where !exact() {
            rig.frame()
            try await Task.sleep(for: .milliseconds(1))
        }
        out.exactAtRest = exact()
        let sorted = out.ms.sorted()
        func p(_ q: Double) -> Double { sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * q).rounded()))] }
        print(String(format: "HOMEWIDTHPASS rows %d loaded %d visited per step min %d max %d step ms p50 %.2f p95 %.2f max %.2f",
                     rows, out.loadedRows, out.visited.min() ?? 0, out.visited.max() ?? 0, p(0.5), p(0.95), sorted.last ?? 0))
        return out
    }

    @Test func aWidthStepMeasuresTheRowsNearTheViewportNotTheLoadedRows() async throws {
        let short = try await drag(rows: 50)
        let long = try await drag(rows: 500)
        let shortMost = short.visited.max() ?? 0, longMost = long.visited.max() ?? 0
        #expect(long.loadedRows >= 10 * short.loadedRows - 100, "the long transcript has ten times the rows (\(long.loadedRows) against \(short.loadedRows))")
        // The same viewport over the same row mix: the rows near it are about as many in both transcripts.
        #expect(Double(longMost) <= Double(shortMost) * 1.25 + 16,
                "a width step of the 500-row Home measured \(longMost) rows, of the 50-row Home \(shortMost): the count follows the loaded rows")
        #expect(longMost < long.loadedRows / 4, "a width step measured \(longMost) of \(long.loadedRows) loaded rows")
        #expect(long.visited.allSatisfy { $0 > 0 }, "every width step measured the rows on screen")
    }

    @Test func everyRowOnScreenIsAtTheTranscriptWidth() async throws {
        let d = try await drag(rows: 500)
        #expect(d.shownAtOtherWidth == 0, "\(d.shownAtOtherWidth) rows on screen were at another width in the drag")
        #expect(d.shownAtOtherWidthAfterScroll == 0,
                "\(d.shownAtOtherWidthAfterScroll) rows on screen were at another width after a scroll to the oldest row")
        #expect(d.exactAtRest, "when the width rests every loaded row is exact at the transcript's width")
    }
}
#endif
