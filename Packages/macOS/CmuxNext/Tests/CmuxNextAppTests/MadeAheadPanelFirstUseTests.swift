@testable import CmuxNextDesign
import CmuxNextHibernation
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Testing

/// Feature `memoryOpenPanelOnFirstUse` (MQ-PROC): the file picker's panel service is not a process at
/// Home idle. The launch's afterStartup post and every agent chat or Home view that reaches a window call
/// `warmWhenIdle()`; on first use none of them makes a panel. The first click makes it, it is kept for later clicks,
/// and the App's overlay page planner (``OverlayPagePlannerRig``) releases it once unused, or at
/// warning pressure, at a look where no sheet shows it. The panels stand in for `NSOpenPanel`, which this test host
/// cannot make without its view service.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct MadeAheadPanelFirstUseTests {
    @MainActor private final class Panel: ReusableOpenPanel {
        var openPanelPrompt: String? = "Open"
        var openPanelMessage: String? = ""
        var isFreeForReuse = true
        func setOpenPanelTexts(prompt: String, message: String) {
            openPanelPrompt = prompt
            openPanelMessage = message
        }
        func resetChoices() {}
    }

    @MainActor private final class Factory {
        private(set) var made: [Panel] = []
        func make() -> Panel {
            let panel = Panel()
            made.append(panel)
            return panel
        }
    }

    private static func store(_ factory: Factory, planner: OverlayPagePlannerRig) -> MadeAheadPanelStore<Panel> {
        MadeAheadPanelStore(clock: ManualClock(), policy: .afterFirstUse(planner.terms()), makePanel: { factory.make() }, warmCheck: { .ready })
    }

    @Test func theLaunchAndViewWarmUpsMakeNoPanel() {
        let factory = Factory()
        let planner = OverlayPagePlannerRig()
        let store = Self.store(factory, planner: planner)
        store.warmWhenIdle()  // the launch's afterStartup post
        store.warmWhenIdle()  // Home's transcript reaching its window
        #expect(!store.isWarming, "a warm-up was armed before any click")
        #expect(factory.made.isEmpty && !store.isMade, "a panel was made at launch")
        #expect(!planner.scheduler.hasDeadline, "a release was armed with no panel")
    }

    @Test func theClickMakesAndKeepsThePanelThenItIsReleasedOnceUnused() async throws {
        let factory = Factory()
        let planner = OverlayPagePlannerRig()
        let store = Self.store(factory, planner: planner)

        let clicked = try #require(store.panel(), "the first click got no panel")
        #expect(factory.made.count == 1 && clicked === factory.made.first)
        #expect(store.isMade, "the first click's panel was not kept for later clicks")
        #expect(planner.scheduler.nextCheck == 300, "no release five minutes after the click")

        await planner.pass(200)
        #expect(try #require(store.panel()) === clicked, "a second click did not reuse the kept panel")
        await planner.pass(101)
        #expect(store.isMade, "the release counted from the first click, not the last")

        await planner.pass(200)
        #expect(!store.isMade && store.releasedPanels == 1, "the unused panel was kept past its release time")
        #expect(planner.scheduler.discardedCount == 1)

        // A view reaching a window after the release makes none: the next warm-up waits for the next click.
        store.warmWhenIdle()
        #expect(!store.isWarming && factory.made.count == 1, "a warm-up remade the released panel with no click")
        _ = try #require(store.panel())
        #expect(factory.made.count == 2 && store.isMade, "the click after a release did not make and keep a panel")
    }

    @Test func aPanelShowingItsSheetIsKeptAndLookedAtOneReleaseTimeLater() async throws {
        let factory = Factory()
        let planner = OverlayPagePlannerRig()
        let store = Self.store(factory, planner: planner)

        let clicked = try #require(store.panel())
        clicked.isFreeForReuse = false  // its sheet shows
        await planner.pass(301)
        #expect(store.isMade && store.releasedPanels == 0, "a panel whose sheet shows was released")
        #expect(planner.scheduler.exemptions.values.contains(.visible), "the planner does not say why the panel stays")
        #expect(planner.scheduler.nextCheck == 300, "a panel in use is looked at again after \(planner.scheduler.nextCheck ?? -1) s, not one release time")

        clicked.isFreeForReuse = true  // the sheet ended
        await planner.pass(300)
        #expect(!store.isMade && store.releasedPanels == 1, "the panel was kept after its sheet ended and its release time passed")
    }

    /// At warning pressure a free panel goes on the urgent pace (hidden 10 s); one whose sheet shows stays, and the
    /// planner looks at it again one release time later, not every second.
    @Test func warningPressureReleasesAFreePanelAndKeepsABusyOneWithoutPolling() async throws {
        let factory = Factory()
        let planner = OverlayPagePlannerRig(level: .warning)
        let store = Self.store(factory, planner: planner)

        _ = try #require(store.panel())
        #expect(store.isMade, "the click's panel was released in the click's turn")
        await planner.pass(11)
        #expect(!store.isMade && store.releasedPanels == 1, "a free panel was kept at warning pressure")

        let busy = try #require(store.panel())
        busy.isFreeForReuse = false
        await planner.pass(11)
        #expect(store.isMade && store.releasedPanels == 1, "a panel whose sheet shows was released at warning pressure")
        let recheck = try #require(planner.scheduler.nextCheck, "a panel in use at warning pressure is never looked at again")
        #expect(recheck >= 300, "a panel in use at warning pressure is looked at again after \(recheck) s")
        busy.isFreeForReuse = true
        await planner.pass(300)
        #expect(!store.isMade && store.releasedPanels == 2)
    }

    /// The default policy keeps the panel for the life of the process: no release is ever armed.
    @Test func aheadMakesThePanelAtTheWarmUpAndArmsNoRelease() async throws {
        let factory = Factory()
        let clock = ManualClock()
        let store = MadeAheadPanelStore(clock: clock, policy: .ahead, makePanel: { factory.make() }, warmCheck: { .ready })
        var checks = store.checksRan.makeAsyncIterator()
        store.warmWhenIdle()
        try await clock.waitForSleeper()
        clock.advance(by: .seconds(2))
        _ = await checks.next()
        #expect(factory.made.count == 1 && store.isMade, "the default policy no longer makes the panel ahead")
        _ = try #require(store.panel())
        #expect(store.releasedPanels == 0)
    }
}
