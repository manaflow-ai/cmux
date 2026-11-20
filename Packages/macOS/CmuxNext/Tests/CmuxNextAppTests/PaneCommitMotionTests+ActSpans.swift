import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextLayout
import CmuxNextTestSupport
import Testing

/// `PaneCommitMotionTests`, the spans that the motion trace (`debug.motion`) gets for the parts of an act's first frame.
///
/// The frame that begins an act's move has work on the main thread beside the move: the motion reads what the screen
/// shows (`arm`), the panes hear their new sizes (`sizes`), the layout reports each pane's presence to the app
/// (`report`), a pass places the pane hosts (`pass`) and the motion starts its moves in that pass (`place`). With the
/// trace on, each part is one span, so a measure of a slow first frame says which part is slow. The spans measure:
/// they take no work away. With the trace off there is no span.
extension PaneCommitMotionTests {
    nonisolated static let actSpans = ["layout.act.arm", "layout.act.pass", "layout.act.place", "layout.act.report", "layout.act.sizes"]

    /// How many spans of each part of an act the trace has now, by name.
    static func actSpanCounts() -> [String: Int] {
        MotionTrace.spans.reduce(into: [:]) { counts, span in
            if span.name.hasPrefix("layout.act.") { counts[span.name, default: 0] += 1 }
        }
    }

    /// Runs frame ticks until the screen's move ends. Returns how many ticks that took.
    static func ticksToTheMovesEnd(_ harness: Commit.Harness, _ screen: ScreenContentView) -> Int {
        var ticks = 0
        repeat {
            _ = harness.root.advanceFrame(dt)
            ticks += 1
        } while inFlight(screen) && ticks < Commit.frames
        return ticks
    }

    /// A zoom and an unzoom of 30 panes with the trace on: each act gives the trace one span of each part. Frames
    /// with no act after them give none. The zoomed pane gets a content that gives its last frame before the unzoom,
    /// so the unzoom moves.
    @Test func anActGivesTheTraceOneSpanForEachPartOfItsFirstFrame() throws {
        let count = 30
        let harness = Commit.Harness(Commit.screen(Self.tree(count)), focused: "p", holds: false) { $0.splitSizingOverride = .even }
        defer { harness.window.closeAfterTest() }
        Self.movePanes(harness)
        Commit.rest(harness)
        let screen = try #require(harness.screen)
        let rest = Self.paneHosts(screen).filter { !$0.isHidden }
        let far = try #require(rest.max { $0.frame.minX + $0.frame.minY < $1.frame.minX + $1.frame.minY }, "SETUP: the screen shows no pane at rest")
        try #require(rest.count == count, "SETUP: at rest the screen shows \(rest.count) panes, not \(count)")
        harness.model.focus(far.pane, notify: false)
        Commit.rest(harness)
        let one = Dictionary(uniqueKeysWithValues: Self.actSpans.map { ($0, 1) })
        defer { MotionTrace.stop() }

        MotionTrace.start()
        harness.model.apply(screens: Commit.screen(.leaf(far.pane), zoomed: true))
        harness.root.syncWithModel()
        let ticks = Self.ticksToTheMovesEnd(harness, screen)
        try #require(ticks > 1 && !Self.inFlight(screen), "SETUP: the zoom's move had \(ticks) frames")
        Commit.rest(harness)
        let zoom = Self.actSpanCounts()
        #expect(zoom == one, "a zoom of \(count) panes gave the trace these spans of its parts (name: count), not one of each of \(Self.actSpans): \(zoom)")

        let content = try #require(harness.provider.contents[far.pane], "SETUP: the zoomed pane has no content")
        let area = PaneContentAreaView(frame: content.bounds), last = Picture(frame: content.bounds)
        area.autoresizingMask = [.width, .height]
        last.autoresizingMask = [.width, .height]
        area.addSubview(last)
        content.addSubview(area)
        MotionTrace.start()
        harness.model.apply(screens: Commit.screen(Self.tree(count)))
        harness.root.syncWithModel()
        let back = Self.ticksToTheMovesEnd(harness, screen)
        try #require(back > 1 && !Self.inFlight(screen), "SETUP: the unzoom's move had \(back) frames")
        Commit.rest(harness)
        let unzoom = Self.actSpanCounts()
        #expect(unzoom == one, "an unzoom of \(count) panes gave the trace these spans of its parts (name: count), not one of each of \(Self.actSpans): \(unzoom)")

        MotionTrace.start()
        harness.root.needsLayout = true
        harness.root.layoutSubtreeIfNeeded()
        for _ in 0..<3 { _ = harness.root.advanceFrame(Self.dt) }
        let still = Self.actSpanCounts()
        #expect(still.isEmpty, "frames with no act gave the trace spans of an act's parts (name: count): \(still)")
    }

    /// With the trace off (as it is until `debug.motion` starts it) a zoom gives the trace no span.
    @Test func withTheTraceOffAnActGivesTheTraceNoSpan() throws {
        let harness = Commit.Harness(Commit.screen(Self.tree(4)), focused: "p", holds: false) { $0.splitSizingOverride = .even }
        defer { harness.window.closeAfterTest() }
        Self.movePanes(harness)
        Commit.rest(harness)
        let screen = try #require(harness.screen)
        let far = try #require(Self.paneHosts(screen).first { !$0.isHidden }, "SETUP: the screen shows no pane at rest")
        harness.model.focus(far.pane, notify: false)
        Commit.rest(harness)
        MotionTrace.start()
        MotionTrace.stop()
        harness.model.apply(screens: Commit.screen(.leaf(far.pane), zoomed: true))
        harness.root.syncWithModel()
        let ticks = Self.ticksToTheMovesEnd(harness, screen)
        try #require(ticks > 1 && !Self.inFlight(screen), "SETUP: the zoom's move had \(ticks) frames")
        #expect(!MotionTrace.isEnabled && MotionTrace.spans.isEmpty, "with the trace off a zoom gave the trace \(MotionTrace.spans.count) spans")
    }

    /// The trace holds a fixed count of spans. A zoom's spans, then more spans than the trace holds: the trace keeps
    /// the zoom's spans, takes no span after it is full, and the answer of `debug.motion` says `spans_full`, so a
    /// reader knows that a later act's spans are not in it.
    @Test func aFullTraceKeepsAnActsSpansAndSaysThatItIsFull() throws {
        let harness = Commit.Harness(Commit.screen(Self.tree(4)), focused: "p", holds: false) { $0.splitSizingOverride = .even }
        defer { harness.window.closeAfterTest() }
        Self.movePanes(harness)
        Commit.rest(harness)
        let screen = try #require(harness.screen)
        let far = try #require(Self.paneHosts(screen).first { !$0.isHidden }, "SETUP: the screen shows no pane at rest")
        harness.model.focus(far.pane, notify: false)
        Commit.rest(harness)
        func saysFull() -> Bool? { MotionDebug.handle(["action": "read"], windows: [])["spans_full"] as? Bool }
        MotionTrace.start()
        defer { MotionTrace.stop() }
        #expect(saysFull() == false, "the answer for a trace with no span says `spans_full` = \(String(describing: saysFull())), not false")
        harness.model.apply(screens: Commit.screen(.leaf(far.pane), zoomed: true))
        harness.root.syncWithModel()
        let ticks = Self.ticksToTheMovesEnd(harness, screen)
        try #require(ticks > 1 && !Self.inFlight(screen), "SETUP: the zoom's move had \(ticks) frames")
        let one = Dictionary(uniqueKeysWithValues: Self.actSpans.map { ($0, 1) })
        let zoom = Self.actSpanCounts()
        #expect(zoom == one, "a zoom gave the trace these spans of its parts (name: count), not one of each: \(zoom)")
        try #require(MotionTrace.spans.count < MotionTrace.capacity, "SETUP: one zoom filled the trace's \(MotionTrace.capacity) spans")
        for _ in 0..<MotionTrace.capacity {
            MotionTrace.begin("row.fill")
            MotionTrace.end("row.fill")
        }
        MotionTrace.begin("row.late")
        MotionTrace.end("row.late")
        #expect(MotionTrace.spans.count == MotionTrace.capacity, "the full trace has \(MotionTrace.spans.count) spans, not \(MotionTrace.capacity)")
        #expect(!MotionTrace.spans.contains { $0.name == "row.late" }, "the full trace took a span that ended after it was full")
        let kept = Self.actSpanCounts()
        #expect(kept == one, "the full trace has these spans of the zoom's parts (name: count), not one of each: \(kept)")
        #expect(saysFull() == true, "the answer for a full trace says `spans_full` = \(String(describing: saysFull())), not true")
    }
}
