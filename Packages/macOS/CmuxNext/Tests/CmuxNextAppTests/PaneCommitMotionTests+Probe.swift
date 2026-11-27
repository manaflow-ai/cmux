import AppKit
import CmuxNextDesign
import CmuxNextTestSupport
@testable import CmuxNextLayout
import Testing

/// What a probe reads of the panes' move while `debug.motion` records: one sample `layout.commit` for each frame tick
/// with a move in flight, and one note for each change that the motion decides on. A pane's move runs on the render
/// server and steps no spring of the layout, so the layout's own samples (`layout.travel`) say nothing of it.
///
/// It reads the time of each loop over an act's panes too, as one span each, and the time of the make of a pane's content.
///
/// The trace is one static of the process. Each test starts it (when its screen rests, or before its first act) and
/// stops it at its end, and has no suspension point, so no other test on the main actor runs in between.
extension PaneCommitMotionTests {
    /// The commit motion's samples and notes from the trace's start on.
    private static func traced() -> (samples: [Double], notes: [String]) {
        (MotionTrace.samples.filter { $0.name == "layout.commit" }.map { $0.value },
         MotionTrace.notes.map { $0.text }.filter { $0.hasPrefix("layout.commit") })
    }

    /// The frame that begins an act's move writes one note of it, each frame tick of the move gives one sample above
    /// zero, and a frame after the move's end gives none.
    @Test(arguments: acts)
    func aProbeCountsEachFrameOfTheMove(_ act: Act) throws {
        defer { MotionTrace.stop() }
        let begun = try Self.begin(act) { _ in MotionTrace.start() }
        defer { begun.harness.window.closeAfterTest() }
        try #require(Self.inFlight(begun.screen), "no pane moves: the act shows in one frame")
        let notes = Self.traced().notes
        #expect(notes.count == 1 && notes[0].contains(" moves "), "the frame that begins the move did not write one note of it: \(notes)")
        let ticks = Self.toTheEnd(begun.harness, begun.screen).ticks
        let samples = Self.traced().samples
        #expect(samples.count == ticks, "the \(ticks) frames of the move gave \(samples.count) samples")
        #expect(samples.allSatisfy { $0 > 0 }, "a frame with a move in flight gave a sample that is not above zero: \(samples)")
        _ = begun.harness.root.advanceFrame(Self.dt)
        #expect(Self.traced().samples.count == ticks, "a frame after the move's end gave a sample")
    }

    /// With the motion off an act gives no sample, and one note of its cause. With Reduce Motion the frame tick lands
    /// the layout, which cancels the act before its frame. With the pane animations off the panes do not move at a
    /// commit.
    @Test(arguments: acts, ["Reduce Motion", "pane animations off"])
    func aProbeSaysWhyAnActShowsInOneFrame(_ act: Act, off: String) throws {
        // The setting is the app's own (`ui.paneAnimations`). This function has no suspension point, so no other test
        // on the main actor runs between the change and its restore.
        let setting = DesignSettings.shared.paneAnimations
        if off != "Reduce Motion" { DesignSettings.shared.paneAnimations = false }
        defer { DesignSettings.shared.paneAnimations = setting }
        defer { MotionTrace.stop() }
        let begun = try Self.begin(act, off: off) { _ in MotionTrace.start() }
        defer { begun.harness.window.closeAfterTest() }
        _ = begun.harness.root.advanceFrame(Self.dt)
        let traced = Self.traced()
        // Movement that snaps for another cause (the Mac's own Reduce Motion) lands the layout in the frame tick too.
        let cause = begun.harness.root.context.reduceMotion ? "cancelled before its frame" : "the panes move at a commit: false"
        #expect(traced.samples.isEmpty, "an act with the motion off gave samples of a move: \(traced.samples)")
        #expect(traced.notes.count == 1 && traced.notes[0].contains(cause),
                "an act with the motion off (\(off)) did not write one note with `\(cause)`: \(traced.notes)")
    }

    /// A view of a kind that does not ride: a page's stand-in, with a class name that a note can tell.
    final class StandInPage: NSView {}

    /// An act with a pane that does not ride gives no sample, and one note that names the class of the top view
    /// that stopped the move.
    @Test(arguments: [PaneCommitMotionTests.split, PaneCommitMotionTests.close])
    func aProbeNamesTheKindThatDoesNotRide(_ act: Act) throws {
        defer { MotionTrace.stop() }
        var placed = false
        let begun = try Self.begin(act) { harness in
            guard let content = harness.provider.contents[Commit.left] else { return }
            let area = PaneContentAreaView(frame: content.bounds)
            area.autoresizingMask = [.width, .height]
            let page = StandInPage(frame: area.bounds)
            page.autoresizingMask = [.width, .height]
            area.addSubview(page)
            content.addSubview(area)
            placed = true
            MotionTrace.start()
        }
        defer { begun.harness.window.closeAfterTest() }
        try #require(placed, "SETUP: the pane has no content")
        _ = begun.harness.root.advanceFrame(Self.dt)
        let traced = Self.traced()
        #expect(traced.samples.isEmpty, "an act with a pane that does not ride gave samples of a move: \(traced.samples)")
        #expect(traced.notes.count == 1 && traced.notes[0].contains("each rides: false, the top view that does not ride: StandInPage"),
                "an act with a pane that does not ride did not write one note with the kind: \(traced.notes)")
    }

    /// Each loop over an act's panes is one span of the record, with its time: the placement loop of the pass that
    /// shows an act (`layout.place`), the hide of the panes that a zoom took out (`layout.hide`), and the show of the
    /// panes that an unzoom brings back (`layout.show`), which comes after that pass's placement. A frame with no
    /// act gives no span.
    @Test func aProbeTimesEachLoopOverAnActsPanes() throws {
        defer { MotionTrace.stop() }
        MotionTrace.start()
        let harness = try Self.unzooming(frames: 1).zoom.harness
        defer { harness.window.closeAfterTest() }
        func spans(_ name: String) -> [MotionTrace.Span] { MotionTrace.spans.filter { $0.name == name } }
        let places = spans("layout.place"), hides = spans("layout.hide"), shows = spans("layout.show")
        #expect(shows.count == 1, "the unzoom's one show of the panes that come back gave \(shows.count) spans")
        let show = try #require(shows.first)
        #expect(!hides.isEmpty && hides.allSatisfy { $0.start < show.start },
                "the zoom's hide of its panes gave no span before the unzoom: \(hides)")
        #expect(places.count >= 2, "the zoom's and the unzoom's placements gave \(places.count) spans")
        #expect(places.last.map { $0.start <= show.start } == true, "the panes that come back showed before the unzoom's placement")
        Commit.rest(harness)
        _ = harness.root.advanceFrame(Self.dt)
        #expect(spans("layout.place").count == places.count && spans("layout.show").count == 1, "a frame with no act gave a span")
    }

    /// The make of a pane's content is one span of the record (`layout.content`), and the layout's turn of a model
    /// change is one time of the record's work (`layout.sync`): a split makes one content, a close makes none.
    @Test(arguments: [split, close])
    func aProbeTimesTheMakeOfAPanesContent(_ act: Act) throws {
        defer { MotionTrace.stop() }
        let begun = try Self.begin(act) { _ in MotionTrace.start() }
        defer { begun.harness.window.closeAfterTest() }
        let makes = MotionTrace.spans.filter { $0.name == "layout.content" }.count
        #expect(makes == (act.name == Self.close.name ? 0 : 1), "the record has \(makes) makes of a pane's content")
        let turns = MotionTrace.work["layout.sync"]?.count ?? 0
        #expect(turns >= 1, "the record has no time of the layout's turn of the act's model change")
    }
}
