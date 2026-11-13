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
///
/// The contract has two parts, and the suite reads both: a row on screen is at the transcript's width in EACH frame
/// (a width step, a scroll in the drag, a change of the display scale, a scroll while a row fades), and ALL loaded
/// rows are at that width, exact, after the width rests. A row no person can see may wait; a row on screen never.
@MainActor @Suite(.serialized) struct HomeWidthPassRowCountTests {
    struct Drag {
        /// Rows handed to measuring, one entry per width step.
        var visited: [Int] = []
        /// Width passes of each width step (every window view's count), and this view's passes near the viewport.
        var passes: [Int] = [], nearPasses: [Int] = []
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

    /// Rows on screen (the cells the list holds) whose width is not the transcript's: the model's row of the cell, and
    /// the row the cell itself last drew (`RowCell.spec`). A fading row (a ghost) is at its old place by design.
    static func shownAtOtherWidth(_ demo: MessagesWindowView) -> Int {
        demo.collection.visibleCells.filter { cell in
            guard let row = demo.collection.indexPath(for: cell).flatMap({ demo.model.rows[checked: $0.item] }), !row.ghost else { return false }
            if row.spec.width != demo.bounds.width { return true }
            guard let drawn = (cell as? RowCell)?.spec, drawn.key == row.spec.key else { return false }
            return drawn.width != demo.bounds.width
        }.count
    }

    /// Loaded rows (no ghost) at a width that is not the transcript's.
    static func rowsAtOtherWidth(_ demo: MessagesWindowView) -> Int {
        demo.model.rows.filter { !$0.ghost && $0.spec.width != demo.bounds.width }.count
    }

    /// A scroll of `dy` points the way AppKit makes it: the scroll view's clip view moves, and the bridge
    /// (`TranscriptScrollView`) sets the list's offset and tells the window view (`userScrolled`). Negative: toward
    /// the oldest row. Returns how far the list moved.
    @discardableResult static func scroll(_ rig: HomeChatRig, _ demo: MessagesWindowView, by dy: CGFloat) -> CGFloat {
        let scrollView = rig.view.controller.host.scrollView, clip = scrollView.contentView
        let before = demo.collection.contentOffset.y
        var to = clip.bounds
        to.origin.y += dy
        clip.scroll(to: clip.constrainBoundsRect(to).origin)
        scrollView.reflectScrolledClipView(clip)
        return demo.collection.contentOffset.y - before
    }

    /// The loaded row under the viewport's y `at` (points from the view's top) and that row's top there.
    static func row(_ demo: MessagesWindowView, at y: CGFloat) -> (key: String, top: CGFloat)? {
        for (i, row) in demo.model.rows.enumerated() where !row.ghost {
            let top = demo.windowY(contentY: demo.layout.frame(for: i).minY)
            if top <= y, y < top + row.spec.total { return (row.spec.key, top) }
        }
        return nil
    }

    /// Where the row `key` is in the viewport now.
    static func top(_ demo: MessagesWindowView, of key: String) -> CGFloat? {
        demo.model.index[key].map { demo.windowY(contentY: demo.layout.frame(for: $0).minY) }
    }

    /// A seeded transcript of `rows` rows in a 700 x 900 pt Home at its newest row, every row exact at 700 pt.
    func seeded(rows: Int) async throws -> (rig: HomeChatRig, demo: MessagesWindowView) {
        let rig = try await HomeChatRig(history: 40, width: 700, height: 900)
        let took = await rig.store.debugSeed(HomeChatRig.conversation, rows: rows)
        #expect(took, "the store took a seed of \(rows) rows")
        guard let demo = rig.view.controller.demo else { rig.stop(); throw Missing.view }
        for _ in 0..<2_000 where demo.model.liveCount < rows {
            rig.frame()
            try await Task.sleep(for: .milliseconds(1))
        }
        // The rows at rest before the drag: exact at 700 pt (an estimated row waits for the off-main measure).
        for _ in 0..<20_000 where demo.model.rows.contains(where: { $0.spec.estimated }) {
            rig.frame()
            try await Task.sleep(for: .milliseconds(1))
        }
        guard demo.model.liveCount >= rows, !demo.model.rows.contains(where: { $0.spec.estimated }) else {
            Issue.record("the Home shows \(demo.model.liveCount) of \(rows) seeded rows, exact \(!demo.model.rows.contains(where: { $0.spec.estimated }))")
            rig.stop()
            throw Missing.seed
        }
        return (rig, demo)
    }

    enum Missing: Error { case view, seed }

    /// Frames until every loaded row is exact at the transcript's width (the width rests: the off-main measure of
    /// every loaded message, then the exact rows). False when that did not come.
    func rest(_ rig: HomeChatRig, _ demo: MessagesWindowView) async throws -> Bool {
        func exact() -> Bool { demo.model.rows.allSatisfy { $0.ghost || ($0.spec.width == demo.bounds.width && !$0.spec.estimated) } }
        for _ in 0..<20_000 where !exact() {
            rig.frame()
            try await Task.sleep(for: .milliseconds(1))
        }
        return exact()
    }

    /// A seeded transcript of `rows` rows in a 700 x 900 pt Home at its newest row, then 30 width steps of 4 pt, one
    /// a frame (what a pane's key resize or a divider drag gives the Home), a scroll to the oldest row, and the rest.
    func drag(rows: Int) async throws -> Drag {
        let (rig, demo) = try await seeded(rows: rows)
        defer { rig.stop() }

        var out = Drag()
        out.loadedRows = demo.model.liveCount
        var width: CGFloat = 700
        let measureCalls = demo.measureWindowCalls, measureStarts = demo.measureWindowStarts
        for _ in 0..<30 {
            width -= 4
            let visited = demo.widthRowsVisited, passes = MessagesWindowView.widthPasses, near = demo.widthPassesNearViewport
            let t0 = CACurrentMediaTime()
            rig.resize(width: width)
            out.ms.append((CACurrentMediaTime() - t0) * 1000)
            out.visited.append(demo.widthRowsVisited - visited)
            out.passes.append(MessagesWindowView.widthPasses - passes)
            out.nearPasses.append(demo.widthPassesNearViewport - near)
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
        out.exactAtRest = try await rest(rig, demo)
        let sorted = out.ms.sorted()
        func p(_ q: Double) -> Double { sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * q).rounded()))] }
        print(String(format: "HOMEWIDTHPASS rows %d loaded %d visited per step min %d max %d step ms p50 %.2f p95 %.2f max %.2f",
                     rows, out.loadedRows, out.visited.min() ?? 0, out.visited.max() ?? 0, p(0.5), p(0.95), sorted.last ?? 0))
        // The rig's width step sets the view's frame and the window's content size: the passes of one step are counted.
        print("HOMEWIDTHPASS rows \(rows) width passes per step min \(out.passes.min() ?? 0) max \(out.passes.max() ?? 0)"
              + ", of them near the viewport min \(out.nearPasses.min() ?? 0) max \(out.nearPasses.max() ?? 0)")
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

    /// A scroll of 3 screens DURING the width change (the lead's case, 2026-11-13): each row on screen is at the
    /// transcript's width in that same frame, and the row under a fixed point of the viewport does not jump when the
    /// far rows take their size at rest. The bar of the jump is half a device pixel (the bar of cmux#41446).
    @Test func aScrollDuringTheWidthChangeShowsEveryRowAtTheTranscriptWidthAndNoJumpAtRest() async throws {
        let (rig, demo) = try await seeded(rows: 500)
        defer { rig.stop() }
        var width: CGFloat = 700, shown = 0, scrolled: CGFloat = 0
        for step in 0..<30 {
            width -= 4
            let scrolls = (10..<20).contains(step)
            // In one frame the scroll comes before the width change, in the next one after it.
            if scrolls, step % 2 == 0 { scrolled += Self.scroll(rig, demo, by: -270) }
            rig.resize(width: width)
            if scrolls, step % 2 == 1 {
                scrolled += Self.scroll(rig, demo, by: -270)
                rig.frame()
            }
            shown += Self.shownAtOtherWidth(demo)
        }
        try #require(scrolled <= -2_690, "the scroll went 3 screens toward the oldest row (it went \(scrolled) pt)")
        #expect(shown == 0, "\(shown) rows on screen were at another width in a drag with a scroll")
        // The far rows are still at their older widths: they take their size at rest.
        let stale = Self.rowsAtOtherWidth(demo)
        try #require(stale > 0, "rows far from the viewport wait for the rest (\(stale) at an older width)")
        let fixed = demo.bounds.height / 2
        let under = try #require(Self.row(demo, at: fixed), "a row is under the middle of the viewport")
        let height = demo.layout.contentHeight
        let rested = try await rest(rig, demo)
        #expect(rested, "when the width rests every loaded row is exact at the transcript's width")
        let after = try #require(Self.top(demo, of: under.key), "the row under the fixed point is still loaded")
        let jump = abs(after - under.top) * demo.renderScale
        print(String(format: "HOMEWIDTHPASS scroll in drag: scrolled %.0f pt, rows at an older width before the rest %d, content height %.1f -> %.1f pt, "
                     + "jump of the row under the viewport's middle at the rest %.3f px (scale %.0f)",
                     scrolled, stale, height, demo.layout.contentHeight, jump, demo.renderScale))
        #expect(jump <= 0.5, "the row under the viewport's middle jumped \(jump) px when the far rows took their size")
        #expect(Self.shownAtOtherWidth(demo) == 0)
    }

    /// A drag in a Home scrolled 3 screens up (the first visible row is the anchor, not the newest row): every row
    /// on screen is at the transcript's width in each step, and the first visible row keeps its place.
    @Test func aDragInAScrolledUpHomeKeepsTheFirstVisibleRowInPlace() async throws {
        let (rig, demo) = try await seeded(rows: 500)
        defer { rig.stop() }
        let scrolled = Self.scroll(rig, demo, by: -2_700)
        rig.frame()
        try #require(scrolled <= -2_690, "the scroll went 3 screens toward the oldest row (it went \(scrolled) pt)")
        var width: CGFloat = 700, shown = 0, worst: CGFloat = 0, visited: [Int] = []
        for _ in 0..<30 {
            width -= 4
            let key = try #require(demo.firstVisibleKey), before = try #require(Self.top(demo, of: key))
            let count = demo.widthRowsVisited
            rig.resize(width: width)
            visited.append(demo.widthRowsVisited - count)
            shown += Self.shownAtOtherWidth(demo)
            worst = max(worst, abs((Self.top(demo, of: key) ?? .infinity) - before) * demo.renderScale)
        }
        print(String(format: "HOMEWIDTHPASS scrolled-up drag: visited per step min %d max %d, first visible row moved at most %.3f px",
                     visited.min() ?? 0, visited.max() ?? 0, worst))
        #expect(shown == 0, "\(shown) rows on screen were at another width in a drag of a scrolled-up Home")
        #expect(worst <= 0.5, "the first visible row moved \(worst) px in a width step")
        #expect((visited.max() ?? 0) < demo.model.liveCount / 4, "a width step measured \(visited.max() ?? 0) of \(demo.model.liveCount) loaded rows")
        let rested = try await rest(rig, demo)
        #expect(rested, "when the width rests every loaded row is exact at the transcript's width")
    }

    /// The display scale changes (the window goes to another display, a zoom change) while rows far from the viewport
    /// are still at an older width: the rows on screen stay at the transcript's width.
    @Test func aScaleChangeBeforeTheRestKeepsEveryRowOnScreenAtTheTranscriptWidth() async throws {
        let (rig, demo) = try await seeded(rows: 500)
        defer { rig.stop() }
        var width: CGFloat = 700
        for _ in 0..<30 {
            width -= 4
            rig.resize(width: width)
        }
        try #require(Self.rowsAtOtherWidth(demo) > 0, "rows far from the viewport wait for the rest")
        try #require(Self.shownAtOtherWidth(demo) == 0)
        // The scale is also the process fallback (`Fixture.renderScale`): the suites after this one get it back.
        let scale = demo.renderScale
        defer { demo.setRenderScale(scale) }
        demo.setRenderScale(scale == 2 ? 1 : 2)
        let shown = Self.shownAtOtherWidth(demo), loaded = Self.rowsAtOtherWidth(demo)
        print("HOMEWIDTHPASS scale change before the rest: rows on screen at another width \(shown), loaded rows at another width \(loaded)")
        #expect(shown == 0, "\(shown) rows on screen were at another width after a scale change")
        // A scale change measures every loaded row again (their heights end on the new device pixels): at this width.
        #expect(loaded == 0, "\(loaded) loaded rows were measured at another width for the new scale")
        let rested = try await rest(rig, demo)
        #expect(rested, "when the width rests every loaded row is exact at the transcript's width")
    }

    /// The pane grows to four times its height before the width rests (a split below it closes): the rows that the
    /// taller view shows are at the transcript's width.
    @Test func aTallerViewBeforeTheRestShowsEveryRowAtTheTranscriptWidth() async throws {
        let (rig, demo) = try await seeded(rows: 500)
        defer { rig.stop() }
        var width: CGFloat = 700
        for _ in 0..<30 {
            width -= 4
            rig.resize(width: width)
        }
        try #require(Self.rowsAtOtherWidth(demo) > 0, "rows far from the viewport wait for the rest")
        rig.view.frame = NSRect(x: 0, y: 0, width: width, height: 3_600)
        rig.window.setContentSize(NSSize(width: width, height: 3_600))
        rig.frame()
        try #require(demo.bounds.height >= 3_500 && demo.bounds.width == width, "the view is 3600 pt high at the same width (\(demo.bounds.size))")
        let shown = Self.shownAtOtherWidth(demo)
        print("HOMEWIDTHPASS taller view before the rest: \(demo.collection.visibleCells.count) rows on screen, at another width \(shown)")
        #expect(shown == 0, "\(shown) rows on screen were at another width in a view that grew to 3600 pt")
        let rested = try await rest(rig, demo)
        #expect(rested, "when the width rests every loaded row is exact at the transcript's width")
    }

    /// One large step with no motion between (a pane zoom with motion off: a 200 pt tile to a 1400 pt pane). The pass
    /// near the viewport reaches two screens at the rows' OLD heights; a long text row in the wide column is about a
    /// sixth as high, so the view shows rows from outside that reach.
    @Test func oneLargeWidthStepShowsEveryRowAtTheTranscriptWidth() async throws {
        let rig = try await HomeChatRig(history: 40, width: 200, height: 900)
        defer { rig.stop() }
        let demo = try #require(rig.view.controller.demo)
        let paragraph = (0..<10).map { "The pane takes sentence \($0) of a long paragraph and wraps it at the width it has now." }.joined(separator: " ")
        for i in 0..<60 {
            let posted = await rig.post("\(i): \(paragraph)", key: IdempotencyKey("long_\(i)"))
            try #require(posted, "the Chief posted long message \(i)")
        }
        func ready() -> Bool { demo.model.liveCount >= 100 && !demo.model.rows.contains(where: { $0.spec.estimated }) }
        for _ in 0..<20_000 where !ready() {
            rig.frame()
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(ready(), "the Home shows the long messages, exact (\(demo.model.liveCount) rows)")
        try #require(Self.rowsAtOtherWidth(demo) == 0, "every loaded row is at 200 pt before the step")
        let near = demo.widthPassesNearViewport, passes = MessagesWindowView.widthPasses
        rig.resize(width: 1_400)
        try #require(demo.bounds.width == 1_400, "the view is 1400 pt wide (\(demo.bounds.width))")
        let shown = Self.shownAtOtherWidth(demo)
        print("HOMEWIDTHPASS one large step 200 -> 1400 pt: \(demo.collection.visibleCells.count) rows on screen, at another width \(shown)"
              + ", loaded rows at another width \(Self.rowsAtOtherWidth(demo)) of \(demo.model.liveCount), width passes"
              + " \(MessagesWindowView.widthPasses - passes) (near the viewport \(demo.widthPassesNearViewport - near))")
        #expect(shown == 0, "\(shown) rows on screen were at another width after one large step")
        let rested = try await rest(rig, demo)
        #expect(rested, "when the width rests every loaded row is exact at the transcript's width")
    }

    /// Return in the field of a Home scrolled 6 screens up, before the width rests: the send takes the transcript to
    /// its newest rows, which the drag did not measure. They are at the transcript's width when they show.
    @Test func aSendFromAScrolledUpHomeBeforeTheRestShowsEveryRowAtTheTranscriptWidth() async throws {
        let (rig, demo) = try await seeded(rows: 500)
        defer { rig.stop() }
        let scrolled = Self.scroll(rig, demo, by: -6_000)
        rig.frame()
        try #require(scrolled <= -5_900, "the scroll went 6 screens toward the oldest row (it went \(scrolled) pt)")
        var width: CGFloat = 700
        for _ in 0..<30 {
            width -= 4
            rig.resize(width: width)
        }
        try #require(Self.rowsAtOtherWidth(demo) > 0, "rows far from the viewport wait for the rest")
        try #require(Self.shownAtOtherWidth(demo) == 0)
        rig.view.controller.dispatch(.setDraft("a send before the width rests"))
        let refusal = rig.view.projection.send()
        try #require(refusal == nil, "the send was taken (\(refusal ?? ""))")
        rig.frame()
        try #require(rig.view.controller.store?.state.ui.scroll.pinnedToBottom == true, "the send took the transcript to its newest row")
        let shown = Self.shownAtOtherWidth(demo)
        print("HOMEWIDTHPASS send from a scrolled-up Home before the rest: rows on screen at another width \(shown)")
        #expect(shown == 0, "\(shown) rows on screen were at another width after a send from a scrolled-up Home")
    }

    /// A scroll while a row fades (the typing row that went away is a ghost for a moment), before the width rests:
    /// the rows the scroll brings on screen are at the transcript's width.
    @Test func aScrollWhileARowFadesShowsEveryRowAtTheTranscriptWidth() async throws {
        let (rig, demo) = try await seeded(rows: 500)
        defer { rig.stop() }
        var width: CGFloat = 700
        for _ in 0..<30 {
            width -= 4
            rig.resize(width: width)
        }
        // The Chief types and stops: the typing row that goes away fades (a ghost until the view's next cleanup).
        rig.store.handle(.typing(HomeChatRig.conversation, rig.chief, on: true))
        rig.frame()
        rig.store.handle(.typing(HomeChatRig.conversation, rig.chief, on: false))
        rig.frame()
        try #require(demo.model.hasGhosts, "the typing row fades (a ghost is in the model)")
        try #require(Self.rowsAtOtherWidth(demo) > 0, "rows far from the viewport wait for the rest")
        // To the oldest row at once, as the first test does, with the ghost still in the model.
        let scrolled = Self.scroll(rig, demo, by: -(demo.collection.contentOffset.y - demo.minOffset))
        rig.frame()
        try #require(scrolled < -2_700, "the scroll went to rows the drag did not measure (it went \(scrolled) pt)")
        let shown = Self.shownAtOtherWidth(demo)
        print("HOMEWIDTHPASS scroll while a row fades: scrolled \(scrolled) pt, ghosts \(demo.model.hasGhosts), rows on screen at another width \(shown)")
        #expect(shown == 0, "\(shown) rows on screen were at another width after a scroll while a row faded")
        let rested = try await rest(rig, demo)
        #expect(rested, "when the width rests every loaded row is exact at the transcript's width")
    }
}
#endif
