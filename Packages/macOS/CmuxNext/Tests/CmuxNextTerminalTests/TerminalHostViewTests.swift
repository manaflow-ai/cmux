import AppKit
@testable import CmuxNextTerminal
import CmuxNextTerminalFind
import CmuxNextWakeups
import Testing

/// The terminal host follows its find controller through FrameObservation (p04-input-027), not one
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
        rig.stop()
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
