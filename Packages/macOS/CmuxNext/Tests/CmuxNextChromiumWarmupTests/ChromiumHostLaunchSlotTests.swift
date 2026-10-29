import CmuxNextChromiumWarmup
import CmuxNextWakeupsTestSupport
import Foundation
import Testing

/// With the Chromium Host the launch decides the host's start once the restore finished,
/// when the restored panes exist: a Chromium page in a shown pane starts it after the first frame, hidden
/// Chromium tabs only after startup, and nothing likely only arms the warm-up. Startup completing with no
/// restore decides then.
@MainActor @Suite struct ChromiumHostLaunchSlotTests {
    @Test func aRestoredShownChromiumPaneStartsTheHostAfterTheFirstFrame() {
        let f = StartupTestScheduler()
        let seen = SlotSeen(ChromiumHostLaunchStart(showsChromiumPane: true, defaultIsChromium: false, hasChromiumTab: true))
        let slot = seen.slot(on: f)

        slot.restored()
        f.hand.drain()
        #expect(slot.decided == .some(seen.decision))
        #expect(f.startup.log.records.map(\.name.description) == ["ChromiumHost.start"])
        f.fire()
        #expect(seen.started.isEmpty, "it waits for the first frame")
        f.startup.firstFrameCommitted()
        f.fire()
        #expect(seen.started == [.restoredTab], "before startup completes")
        #expect(seen.armed == 0)
    }

    @Test func restoredHiddenChromiumTabsStartTheHostOnlyAfterStartup() {
        let f = StartupTestScheduler()
        let seen = SlotSeen(ChromiumHostLaunchStart(showsChromiumPane: false, defaultIsChromium: false, hasChromiumTab: true))
        let slot = seen.slot(on: f)

        slot.restored()
        f.hand.drain()
        #expect(slot.decided??.priority == .afterStartup)
        f.startup.firstFrameCommitted()
        f.fire()
        #expect(seen.started.isEmpty, "afterStartup waits for completion")
        f.complete()
        f.fire()
        f.fire()
        #expect(seen.started == [.restoredTab])
    }

    /// Chromium as the default engine starts the host at the first frame, before startup
    /// completes, and never before the first frame.
    @Test func chromiumAsTheDefaultEngineStartsTheHostAtTheFirstFrame() {
        let f = StartupTestScheduler()
        let seen = SlotSeen(ChromiumHostLaunchStart(showsChromiumPane: false, defaultIsChromium: true, hasChromiumTab: false))
        let slot = seen.slot(on: f)

        slot.restored()
        f.hand.drain()
        f.fire()
        #expect(seen.started.isEmpty, "the host started before the first frame")
        f.startup.firstFrameCommitted()
        f.fire()
        #expect(seen.started == [.launch], "it waited for startup to complete")
        #expect(f.startup.completion == nil)
    }

    /// Before the restore no pane shows its Chromium tab yet: the slot reads the panes only once it finished.
    @Test func theDecisionWaitsForTheRestore() {
        let f = StartupTestScheduler()
        let seen = SlotSeen(ChromiumHostLaunchStart(showsChromiumPane: true, defaultIsChromium: false, hasChromiumTab: true))
        let slot = seen.slot(on: f)

        f.startup.firstFrameCommitted()
        f.fire()
        f.hand.drain()
        #expect(seen.decides == 0, "it decided before the restore")
        #expect(slot.decided == nil)

        slot.restored()
        slot.restored()
        f.hand.drain()
        f.fire()
        #expect(seen.decides == 1)
        #expect(seen.started == [.restoredTab], "the restore came after the first frame: it runs at the next frame")
    }

    @Test func nothingLikelyOnlyArmsTheWarmupAfterTheFirstFrame() {
        let f = StartupTestScheduler()
        let seen = SlotSeen(nil)
        let slot = seen.slot(on: f)

        slot.restored()
        f.hand.drain()
        #expect(slot.decided == .some(nil))
        #expect(f.startup.log.records.map(\.name.description) == ["ChromiumWarmup.arm"])
        f.startup.firstFrameCommitted()
        f.fire()
        #expect(seen.armed == 1)
        #expect(seen.started.isEmpty)
    }

    @Test func startupCompleteWithNoRestoreDecidesThen() {
        let f = StartupTestScheduler()
        let seen = SlotSeen(ChromiumHostLaunchStart(showsChromiumPane: false, defaultIsChromium: true, hasChromiumTab: false))
        let slot = seen.slot(on: f)

        f.complete()
        f.hand.drain()
        f.fire()
        f.fire()
        #expect(seen.started == [.launch], "a launch with no restore (daemon unavailable, failsafe) still starts the host")
        slot.restored()
        f.hand.drain()
        f.fire()
        #expect(seen.decides == 1, "decided twice")
        #expect(seen.started == [.launch])
    }
}

/// What a slot decided and ran.
@MainActor private final class SlotSeen {
    let decision: ChromiumHostLaunchStart?
    private(set) var decides = 0
    private(set) var started: [ChromiumWarmup.Reason] = []
    private(set) var armed = 0

    init(_ decision: ChromiumHostLaunchStart?) {
        self.decision = decision
    }

    func slot(on f: StartupTestScheduler) -> ChromiumHostLaunchSlot {
        ChromiumHostLaunchSlot(startup: f.startup, decide: { [self] in
            decides += 1
            return decision
        }, start: { [self] start in started.append(start.reason) }, noStart: { [self] in armed += 1 })
    }
}
