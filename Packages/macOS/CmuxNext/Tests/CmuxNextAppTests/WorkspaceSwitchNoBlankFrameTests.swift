import AppKit
import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextTestSupport
import Testing
import CmuxNextWakeupsTestSupport

/// Leo 2026-11-15: "it should be instant even under load". A workspace that appears (new, or switched to cold) shows
/// its content in the first frame that shows it, and the old one stays until then. A pane's tab switch already waits
/// for a page that has not painted (`TabSwitchNoBlankFrameTests`); the window's workspace swap waited only for a
/// resize, so a workspace whose New Tab page or chat had not painted showed a clear pane or a loading cover in place
/// of the outgoing workspace, for as long as the page took (longer under load). Runs a real window root.
@MainActor @Suite(.serialized, .closesItsWindows) struct WorkspaceSwitchNoBlankFrameTests {
    /// A page that draws nothing until it paints, as an agent or New Tab page does.
    final class UnpaintedPage: NSView, PaneFirstPaintGated {
        private var painted = false
        private var waiting: [() -> Void] = []
        /// The picture it keeps of itself (a chat's last frame), shown only while it stands in.
        let picture = NSView()
        private(set) var stoodIn = 0
        var awaitsFirstPaint: Bool { !painted }
        func whenFirstPainted(_ body: @escaping () -> Void) {
            if painted { body() } else { waiting.append(body) }
        }

        override init(frame: NSRect) {
            super.init(frame: frame)
            picture.isHidden = true
            addSubview(picture)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        /// It keeps a picture of itself (a chat shown before); false: a brand-new page.
        var hasPicture = true

        func standInUntilPainted() -> Bool {
            stoodIn += 1
            guard hasPicture else { return false }
            picture.isHidden = false
            return true
        }

        func paint() {
            painted = true
            picture.isHidden = true
            let callbacks = waiting
            waiting = []
            callbacks.forEach { $0() }
        }
    }

    /// A window root whose swap hold runs on `clock` at a screen of `framesPerSecond`.
    static func root(clock: ManualClock, framesPerSecond: Int) -> (NSWindow, WindowRootView) {
        let (window, root) = WorkspaceSwitchRedrawHoldTests.root()
        root.paintHold.clock = clock
        root.paintHold.displayFramesPerSecond = { _ in framesPerSecond }
        return (window, root)
    }

    /// Two frames at `framesPerSecond`, as a display draws them.
    static func twoFrames(at framesPerSecond: Int) -> Duration { .nanoseconds(2_000_000_000 / Int64(framesPerSecond)) }

    /// Lets the hold's deadline, which hops to the main actor, run; true once `condition` holds (no sleep, no wall wait
    /// past 2 s).
    static func settles(_ condition: () -> Bool) async -> Bool {
        let by = ContinuousClock.now + .seconds(2)
        while !condition(), ContinuousClock.now < by { await Task.yield() }
        return condition()
    }

    /// The forced never-paints case on the wall clock, for the A/B (no limit asserted: it is a measure): five switches to
    /// a workspace whose page never paints, each timed from the switch to the frame the workspace shows in, and whether
    /// its page showed its picture then (`never-paints:` line).
    @Test(arguments: [true, false]) func neverPaintsTimeToFirstVisible(hasPicture: Bool) async throws {
        var times: [Double] = [], pictures = 0
        for _ in 0..<5 {
            let (window, root) = WorkspaceSwitchRedrawHoldTests.root()
            let old = WorkspaceSwitchRedrawHoldTests.workspace(NSView())
            WorkspaceSwitchRedrawHoldTests.show(old, in: root)
            let page = UnpaintedPage()
            page.hasPicture = hasPicture
            let new = WorkspaceSwitchRedrawHoldTests.workspace(page)
            let start = ContinuousClock.now
            root.show(new)
            let shown = await Self.settles { new.alphaValue == 1 }
            let took = ContinuousClock.now - start
            times.append(Double(took.components.seconds) * 1000 + Double(took.components.attoseconds) / 1e15)
            if !page.picture.isHidden { pictures += 1 }
            window.close()
            #expect(shown, "a page that never paints kept its workspace unseen past 2 s")
        }
        let sorted = times.sorted()
        print("never-paints (\(hasPicture ? "has a picture" : "no picture")): first visible ms \(sorted.map { ($0 * 10).rounded() / 10 }) p50 \(sorted[2]) max \(sorted[4]); with its picture \(pictures)/5")
    }

    /// interim-coord 2026-11-17: "500 ms worst case is too long for a switch ... bring the cap down to about 2 frames
    /// (~33 ms at 60 Hz, adaptive to refresh rate)". A page that never paints shows two frames of its screen after the
    /// switch, not 500 ms.
    @Test(arguments: [60, 120]) func aPageThatNeverPaintsShowsTwoFramesAfterTheSwitch(framesPerSecond: Int) async throws {
        let clock = ManualClock()
        let (window, root) = Self.root(clock: clock, framesPerSecond: framesPerSecond)
        defer { window.close() }
        let old = WorkspaceSwitchRedrawHoldTests.workspace(NSView())
        WorkspaceSwitchRedrawHoldTests.show(old, in: root)
        let page = UnpaintedPage()
        let new = WorkspaceSwitchRedrawHoldTests.workspace(page)
        root.show(new)
        #expect(new.alphaValue == 0 && !old.isHidden)
        try await clock.waitForSleeper()
        let limit = Self.twoFrames(at: framesPerSecond)
        #expect(clock.sleeperDeadlines.map(\.offset) == [limit], "the hold's limit is not two frames at \(framesPerSecond) Hz")
        clock.advance(by: limit)
        #expect(await Self.settles { new.alphaValue == 1 && old.isHidden },
                "a page that never painted kept the old workspace past two frames at \(framesPerSecond) Hz")
    }

    /// interim-coord 2026-11-17: "show the cached snapshot for anything still unpainted". At the limit the page shows
    /// its picture, in the frame the workspace shows, not a clear pane; once it paints, its own frame.
    @Test func aPageStillUnpaintedAtTheLimitShowsItsPicture() async throws {
        let clock = ManualClock()
        let (window, root) = Self.root(clock: clock, framesPerSecond: 60)
        defer { window.close() }
        let old = WorkspaceSwitchRedrawHoldTests.workspace(NSView())
        WorkspaceSwitchRedrawHoldTests.show(old, in: root)
        let page = UnpaintedPage()
        let new = WorkspaceSwitchRedrawHoldTests.workspace(page)
        root.show(new)
        try await clock.waitForSleeper()
        clock.advance(by: Self.twoFrames(at: 60))
        #expect(await Self.settles { new.alphaValue == 1 })
        #expect(page.stoodIn == 1 && !page.picture.isHidden, "the unpainted page showed clear, not its picture")
        page.paint()
        #expect(page.picture.isHidden && new.alphaValue == 1)
    }

    /// A page with no picture of itself (a brand-new chat, a New Tab page whose engine draws over covers) would show clear
    /// at two frames: it keeps today's hold, the old workspace until it paints or ``PanePaintHold/limit`` passes.
    @Test func aPageWithNoPictureKeepsTheOldWorkspaceUntilTheLongerLimit() async throws {
        let clock = ManualClock()
        let (window, root) = Self.root(clock: clock, framesPerSecond: 60)
        defer { window.close() }
        let old = WorkspaceSwitchRedrawHoldTests.workspace(NSView())
        WorkspaceSwitchRedrawHoldTests.show(old, in: root)
        let page = UnpaintedPage()
        page.hasPicture = false
        let new = WorkspaceSwitchRedrawHoldTests.workspace(page)
        root.show(new)
        try await clock.waitForSleeper()
        clock.advance(by: Self.twoFrames(at: 60))
        #expect(await Self.settles { page.stoodIn == 1 }, "the page was not asked for its picture at two frames")
        for _ in 0..<100 { await Task.yield() }
        #expect(new.alphaValue == 0 && !old.isHidden, "a page with no picture showed clear at two frames")
        try await clock.waitForSleeper()
        clock.advance(by: PanePaintHold.limit - Self.twoFrames(at: 60))
        #expect(await Self.settles { new.alphaValue == 1 && old.isHidden }, "the hold outlived its 500 ms limit")
    }

    /// Fifty quick Cmd-Ns (`RapidWorkspaceCreateTests`): each swap that hands the hold on starts its own two frames, so
    /// a run of swaps faster than that keeps one view on screen and never shows, or stands in, the ones it passes over
    /// (ending holds mid-burst showed each one and started a new hold on it, cmux#44329).
    @Test func swapsFasterThanTwoFramesKeepTheShownWorkspaceAndNeverShowTheOnesPassedOver() async throws {
        let clock = ManualClock()
        let (window, root) = Self.root(clock: clock, framesPerSecond: 60)
        defer { window.close() }
        let old = WorkspaceSwitchRedrawHoldTests.workspace(NSView())
        WorkspaceSwitchRedrawHoldTests.show(old, in: root)
        let first = UnpaintedPage(), second = UnpaintedPage()
        let a = WorkspaceSwitchRedrawHoldTests.workspace(first), b = WorkspaceSwitchRedrawHoldTests.workspace(second)
        let limit = Self.twoFrames(at: 60)
        root.show(a)
        try await clock.waitForSleeper()
        clock.advance(by: limit / 2)
        root.show(b)
        try await clock.waitForSleeper()
        clock.advance(by: limit / 2 + .milliseconds(1)) // past A's two frames, inside B's
        for _ in 0..<100 { await Task.yield() } // a deadline that wrongly fired runs by now
        #expect(!old.isHidden && old.alphaValue == 1 && b.alphaValue == 0, "the hand-off kept A's limit")
        clock.advance(by: limit)
        #expect(await Self.settles { b.alphaValue == 1 && old.isHidden }, "B never showed at its limit")
        #expect(a.isHidden && first.stoodIn == 0, "the workspace passed over showed or stood in")
        #expect(second.stoodIn == 1)
    }

    @Test func aNewWorkspaceWhosePageHasNotPaintedKeepsTheOldOneUntilItPaints() {
        let (window, root) = WorkspaceSwitchRedrawHoldTests.root()
        defer { window.close() }
        let old = WorkspaceSwitchRedrawHoldTests.workspace(NSView())
        WorkspaceSwitchRedrawHoldTests.show(old, in: root)
        let page = UnpaintedPage()
        let new = WorkspaceSwitchRedrawHoldTests.workspace(page)
        root.show(new)
        root.layoutSubtreeIfNeeded()
        #expect(new.alphaValue == 0, "the new workspace showed before its page painted: a clear pane in its first frame")
        #expect(!old.isHidden && old.alphaValue == 1, "the old workspace left before the new one had a frame")
        page.paint()
        #expect(new.alphaValue == 1, "the new workspace stayed unseen after its page painted")
        #expect(old.isHidden, "the old workspace stayed after the new one showed")
    }

    @Test func aParkedWorkspaceWhosePageHasNotPaintedKeepsTheShownOneUntilItPaints() {
        let (window, root) = WorkspaceSwitchRedrawHoldTests.root()
        defer { window.close() }
        let page = UnpaintedPage()
        let cold = WorkspaceSwitchRedrawHoldTests.workspace(page)
        WorkspaceSwitchRedrawHoldTests.show(cold, in: root) // the window's first: nothing to keep
        let shown = WorkspaceSwitchRedrawHoldTests.workspace(NSView())
        WorkspaceSwitchRedrawHoldTests.show(shown, in: root)
        #expect(cold.isHidden)
        root.show(cold)
        #expect(cold.alphaValue == 0, "a switch to a workspace whose page has not painted showed it clear")
        #expect(!shown.isHidden, "the shown workspace left before the one switched to had a frame")
        page.paint()
        #expect(cold.alphaValue == 1)
        #expect(shown.isHidden)
    }

    @Test func rapidSwitchesThroughUnpaintedWorkspacesKeepTheLastShownOne() {
        let (window, root) = WorkspaceSwitchRedrawHoldTests.root()
        defer { window.close() }
        let old = WorkspaceSwitchRedrawHoldTests.workspace(NSView())
        WorkspaceSwitchRedrawHoldTests.show(old, in: root)
        let first = UnpaintedPage(), second = UnpaintedPage()
        let a = WorkspaceSwitchRedrawHoldTests.workspace(first), b = WorkspaceSwitchRedrawHoldTests.workspace(second)
        root.show(a)
        root.show(b)
        #expect(!old.isHidden && old.alphaValue == 1, "a second switch before the first workspace painted went blank")
        #expect(b.alphaValue == 0)
        #expect(a.isHidden || a.alphaValue == 0, "the workspace passed over showed")
        second.paint()
        #expect(b.alphaValue == 1)
        #expect(old.isHidden)
    }

    /// Fifty quick Cmd-Ns (`RapidWorkspaceCreateTests`): a held workspace is laid out by the window's own pass, not in the
    /// press's turn, so one the next press passes over before that pass costs no layout (worst press-to-row 424 ms with a
    /// layout per press, cmux#44329).
    @Test func aHeldWorkspaceIsNotLaidOutInThePresssTurn() {
        let (window, root) = WorkspaceSwitchRedrawHoldTests.root()
        defer { window.close() }
        let old = WorkspaceSwitchRedrawHoldTests.workspace(NSView())
        WorkspaceSwitchRedrawHoldTests.show(old, in: root)
        let first = UnpaintedPage(), second = UnpaintedPage()
        let a = WorkspaceSwitchRedrawHoldTests.workspace(first), b = WorkspaceSwitchRedrawHoldTests.workspace(second)
        root.show(a)
        #expect(a.needsLayout, "the held workspace was laid out in the press's turn")
        root.show(b)
        #expect(a.isHidden && a.needsLayout, "the workspace passed over was laid out")
        #expect(!old.isHidden && old.alphaValue == 1 && b.alphaValue == 0)
        root.layoutSubtreeIfNeeded()
        #expect(!b.needsLayout, "the window's pass did not lay out the held workspace")
        second.paint()
        #expect(b.alphaValue == 1 && old.isHidden)
    }

    /// A page its own pane keeps unseen (its tab-switch hold) is not the workspace's to wait for: the pane shows what it kept.
    @Test func aPageItsPaneAlreadyHoldsDoesNotHoldTheSwitch() {
        let (window, root) = WorkspaceSwitchRedrawHoldTests.root()
        defer { window.close() }
        let old = WorkspaceSwitchRedrawHoldTests.workspace(NSView())
        WorkspaceSwitchRedrawHoldTests.show(old, in: root)
        let page = UnpaintedPage()
        page.alphaValue = 0
        let new = WorkspaceSwitchRedrawHoldTests.workspace(page)
        root.show(new)
        #expect(new.alphaValue == 1)
        #expect(old.isHidden)
    }

    /// Cmd-N's reserved view was pre-rendered off screen in the window before the key (`CmdNPrebuiltWorkspaceViewTests`):
    /// the key shows it at once, as designed, even if its New Tab page has not reported a paint.
    @Test func cmdNsReservedViewShowsAtOnce() {
        let (window, root) = WorkspaceSwitchRedrawHoldTests.root()
        defer { window.close() }
        let old = WorkspaceSwitchRedrawHoldTests.workspace(NSView())
        WorkspaceSwitchRedrawHoldTests.show(old, in: root)
        let reserved = WorkspaceSwitchRedrawHoldTests.workspace(UnpaintedPage())
        reserved.setParked(true)
        reserved.alphaValue = 0
        root.contentHost.addSubview(reserved)
        root.show(reserved)
        #expect(reserved.alphaValue == 1, "Cmd-N's pre-rendered view waited for its page")
        #expect(old.isHidden)
    }

    @Test func aWorkspaceWhosePagesPaintedShowsAtOnce() {
        let (window, root) = WorkspaceSwitchRedrawHoldTests.root()
        defer { window.close() }
        let old = WorkspaceSwitchRedrawHoldTests.workspace(NSView())
        WorkspaceSwitchRedrawHoldTests.show(old, in: root)
        let page = UnpaintedPage()
        page.paint()
        let new = WorkspaceSwitchRedrawHoldTests.workspace(page)
        root.show(new)
        #expect(new.alphaValue == 1, "a workspace whose page painted waited")
        #expect(old.isHidden)
    }
}
