import AppKit
@testable import CmuxNextTerminal
import CmuxNextTerminalFind
import CmuxNextWakeups
import Testing

/// The terminal host follows its find controller through FrameObservation, not one
/// `withObservationTracking` hop per change: Cmd-F (a person's change) builds the find bar in the
/// key's own input-response pass, a program's open builds it in the next frame, and a burst of
/// query changes renders the bar once per frame.
@MainActor @Suite struct TerminalHostViewTests {
    static func findBars(in host: NSView) -> [TerminalFindBarView] {
        host.subviews.compactMap { $0 as? TerminalFindBarView }
    }

    @Test func cmdFBuildsTheFindBarInTheKeysOwnTurn() {
        _ = NSApplication.shared
        let rig = TerminalFrameRig()
        let host = TerminalHostView(mainWork: rig.work)
        let find = TerminalFindController()
        host.attachFind(find)
        #expect(Self.findBars(in: host).isEmpty, "the bar was built before find opened")
        rig.work.causes.withCause(.person) { find.open() }
        #expect(Self.findBars(in: host).isEmpty, "the open built the bar inside its own will-set")
        #expect(rig.work.causes.flushPersonCaused() == 1, "the open did not wait for the input-response pass")
        #expect(Self.findBars(in: host).count == 1, "Cmd-F's bar waited for a later frame")
        rig.frame()
        #expect(Self.findBars(in: host).count == 1, "the scheduled apply built a second bar")
        rig.stop()
    }

    @Test func aProgramOpenBuildsTheBarInTheNextFrameOnce() {
        _ = NSApplication.shared
        let rig = TerminalFrameRig()
        let host = TerminalHostView(mainWork: rig.work)
        let find = TerminalFindController()
        host.attachFind(find)
        find.open(takeFocus: false)
        find.close(restoringFocus: false)
        find.open(takeFocus: false)
        #expect(Self.findBars(in: host).isEmpty, "a program's open built the bar in its own turn")
        rig.frame()
        #expect(Self.findBars(in: host).count == 1)
        find.close(restoringFocus: false)
        find.open(takeFocus: false)
        rig.frame()
        #expect(Self.findBars(in: host).count == 1, "reopening built another bar")
        rig.stop()
    }

    @Test func aQueryBurstRendersTheBarOnceInTheNextFrame() throws {
        _ = NSApplication.shared
        let rig = TerminalFrameRig()
        let host = TerminalHostView(mainWork: rig.work)
        let find = TerminalFindController()
        find.open(takeFocus: false)
        host.attachFind(find)
        let bar = try #require(Self.findBars(in: host).first)
        #expect(bar.pill.query.isEmpty)
        for text in ["e", "er", "err", "erro", "error"] { find.updateQuery(text) }
        #expect(bar.pill.query.isEmpty, "the bar rendered a query in the change's own turn")
        rig.frame()
        #expect(bar.pill.query == "error")
        #expect(bar.watch?.deliveriesScheduled == 1, "five query changes scheduled \(bar.watch?.deliveriesScheduled ?? 0) renders")
        rig.stop()
    }

    /// Typing in the bar and Escape are the person's changes: the bar renders them in that key's
    /// input-response pass, not a frame later.
    @Test func theBarsOwnTypingAndEscapeRenderInTheKeysPass() throws {
        _ = NSApplication.shared
        let rig = TerminalFrameRig()
        let host = TerminalHostView(mainWork: rig.work)
        let find = TerminalFindController()
        find.open(takeFocus: false)
        host.attachFind(find)
        let bar = try #require(Self.findBars(in: host).first)
        let typed = try #require(bar.pill.onQueryChange)
        typed("error")
        #expect(rig.work.causes.flushPersonCaused() == 1, "typing in the bar waited for a later frame")
        #expect(bar.watch?.value.query == "error")
        let command = try #require(bar.pill.onCommand)
        command(.close)
        #expect(bar.pill.isPresented, "Escape hid the pill inside its own change")
        #expect(rig.work.causes.flushPersonCaused() == 1, "Escape waited for a later frame")
        #expect(!bar.pill.isPresented, "the pill stayed after Escape's pass")
        rig.stop()
    }

    @Test func scrollbarChangesReachTheScrollerOnceInTheNextFrame() throws {
        _ = NSApplication.shared
        GhosttyRuntime.startedForTests()
        let rig = TerminalFrameRig()
        let io = ScriptedTerminalIO()
        defer { io.finish() }
        let session = TerminalSession(io: io, mainWork: rig.work)
        let watch = try #require(session.view.scrollbarWatch)
        for offset in 1...5 { session.model.scrollbar = Self.bar(offset) }
        #expect(session.view.scroller.shown == nil, "the scroller moved in the change's own turn")
        rig.frame()
        #expect(session.view.scroller.shown == Self.bar(5))
        #expect(watch.deliveriesScheduled == 1, "five scrollbar changes scheduled \(watch.deliveriesScheduled) applies")
        rig.stop()
    }

    /// Streaming output: each frame's burst of scrollbar changes places the knob once,
    /// and a frame with no change places nothing; the scroller adds no frame client of its own.
    @Test func streamingOutputPlacesTheKnobOncePerFrame() throws {
        _ = NSApplication.shared
        GhosttyRuntime.startedForTests()
        let rig = TerminalFrameRig()
        let io = ScriptedTerminalIO()
        defer { io.finish() }
        let session = TerminalSession(io: io, mainWork: rig.work)
        let scroller = session.view.scroller
        var placements = scroller.knobPlacements
        for frame in 0..<4 {
            for offset in 1...3 { session.model.scrollbar = Self.bar(frame * 10 + offset) }
            rig.frame()
            #expect(scroller.knobPlacements == placements + 1, "frame \(frame) placed the knob \(scroller.knobPlacements - placements) times")
            #expect(scroller.shown == Self.bar(frame * 10 + 3))
            placements = scroller.knobPlacements
        }
        rig.frame()
        #expect(scroller.knobPlacements == placements, "a frame with no change placed the knob")
        #expect(!rig.work.frames.activeClients.contains { $0.hasPrefix("Terminal.scroller") }, "the scroller keeps frames of its own")
        rig.stop()
    }

    /// Two of a person's scrolls in one frame: each places the knob in its own input-response pass,
    /// before the commit, so the knob is never drawn a frame after the content it describes.
    @Test func aPersonsScrollsPlaceTheKnobInTheirOwnPass() throws {
        _ = NSApplication.shared
        GhosttyRuntime.startedForTests()
        let rig = TerminalFrameRig()
        let io = ScriptedTerminalIO()
        defer { io.finish() }
        let session = TerminalSession(io: io, mainWork: rig.work)
        rig.work.causes.withCause(.person) { session.model.scrollbar = Self.bar(40) }
        #expect(rig.work.causes.flushPersonCaused() == 1)
        #expect(session.view.scroller.shown == Self.bar(40), "the first scroll's knob waited for a frame")
        rig.work.causes.withCause(.person) { session.model.scrollbar = Self.bar(30) }
        #expect(rig.work.causes.flushPersonCaused() == 1)
        #expect(session.view.scroller.shown == Self.bar(30), "the second scroll's knob waited for a frame")
        rig.stop()
    }

    @Test func aSurfaceSwapCancelsTheOldSurfacesScrollbarWatch() throws {
        _ = NSApplication.shared
        GhosttyRuntime.startedForTests()
        let rig = TerminalFrameRig()
        let (firstIO, secondIO) = (ScriptedTerminalIO(), ScriptedTerminalIO())
        defer { firstIO.finish(); secondIO.finish() }
        let first = TerminalSession(io: firstIO, mainWork: rig.work), second = TerminalSession(io: secondIO, mainWork: rig.work)
        let old = try #require(first.view.scrollbarWatch)
        first.view.install(second.surfaceView)
        #expect(old.isCancelled, "the replaced surface's watch kept following")
        let new = try #require(first.view.scrollbarWatch)
        #expect(new !== old)
        first.model.scrollbar = Self.bar(1)
        rig.frame()
        #expect(first.view.scroller.shown == nil, "the replaced surface's scrollbar reached the scroller")
        second.model.scrollbar = Self.bar(2)
        rig.frame()
        #expect(first.view.scroller.shown == Self.bar(2))
        rig.stop()
    }

    /// A terminal whose tab is hidden (another tab selected, a hidden workspace) does no scroller work
    /// for its output: it tracks nothing, and reads once when the tab shows.
    @Test func aHiddenTerminalsScrollbarAppliesOnceWhenItShows() throws {
        _ = NSApplication.shared
        GhosttyRuntime.startedForTests()
        let rig = TerminalFrameRig()
        let io = ScriptedTerminalIO()
        defer { io.finish() }
        let node = VisibilityNode(root: "tab", own: .hidden)
        let session = TerminalSession(io: io, mainWork: rig.work, node: node)
        let watch = try #require(session.view.scrollbarWatch)
        for offset in 1...5 { session.model.scrollbar = Self.bar(offset) }
        rig.frame()
        #expect(session.view.scroller.shown == nil, "a hidden terminal's scroller followed its output")
        #expect(watch.deliveriesScheduled == 0 && watch.trackingCallbacks == 0, "a hidden terminal tracked its scrollbar")
        node.set(.visible)
        #expect(session.view.scroller.shown == Self.bar(5), "the shown terminal did not read its scrollbar")
        #expect(watch.deliveriesScheduled == 0, "showing scheduled an apply instead of reading once")
        rig.stop()
    }

    @Test func aTextBoxShowsACycleAndATextSetOnceInTheNextFrame() throws {
        _ = NSApplication.shared
        let rig = TerminalFrameRig()
        let model = TextBoxModel()
        try #require(model.catalog.count > 1)
        let view = TextBoxView(model: model, mainWork: rig.work, node: nil)
        let watch = try #require(view.watch)
        model.cycle()
        model.text = "make test"
        model.isVisible = true
        #expect(view.textView.string.isEmpty && view.isHidden, "the strip showed a change in its own turn")
        rig.frame()
        #expect(view.textView.string == "make test" && !view.isHidden)
        #expect(watch.value.action == model.action)
        #expect(watch.deliveriesScheduled == 1, "three model changes scheduled \(watch.deliveriesScheduled) applies")
        rig.stop()
    }

    static func bar(_ offset: Int) -> TerminalScrollbar {
        TerminalScrollbar(totalRows: 100, offsetRows: UInt64(offset), visibleRows: 24)
    }
}

/// The app's one main-thread scheduler on a hand-fired link, kept running by a frame client so a
/// program's change waits for the next ``frame()``.
@MainActor private final class TerminalFrameRig {
    let work: MainWorkScheduler
    private let clock = TerminalFrameClock()
    private var timestamp: Double = 0
    private var keeper: FrameClient?

    init() {
        let clock = self.clock
        work = MainWorkScheduler.testing(budget: MainFrameBudget(uptimeNanos: clock.read)) { _ -> (any FrameLink)? in
            TerminalFrameLink()
        }
        let keeper = FrameClient(owner: "test.terminalKeeper", isAnimation: false, on: work.frames) { _ in true }
        keeper.activate()
        self.keeper = keeper
    }

    /// One display frame, 17 ms after the last.
    func frame() {
        clock.advance(ms: 17)
        timestamp += 1
        work.frameDidFire(timestamp: timestamp, refreshInterval: 1.0 / 60)
    }

    func stop() {
        keeper?.deactivate()
    }
}

@MainActor private final class TerminalFrameClock {
    private var now: UInt64 = 1_000_000_000
    var read: () -> UInt64 { { [self] in self.now } }
    func advance(ms: UInt64) { now += ms * 1_000_000 }
}

@MainActor private final class TerminalFrameLink: FrameLink {
    var isPaused = false
    func invalidate() {}
}
