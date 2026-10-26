@testable import CmuxNextDesign
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Testing

/// Feature `memoryOpenPanelOnFirstUse` (p07-memory-062, MQ-PROC): the file picker's panel service is not a process at
/// Home idle. The launch's afterStartup post and every agent chat or Home view that reaches a window call
/// `warmWhenIdle()`; on first use none of them makes a panel. The first click makes it, it is kept for later clicks,
/// and a background deadline on the app's placer releases it once unused. The deadline fires on a hand-fired
/// ``MainDeadlineRig``; the panels stand in for `NSOpenPanel`, which this test host cannot make without its view service.
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

    private static let releaseAfter = Duration.seconds(300)

    private static func store(_ factory: Factory, rig: MainDeadlineRig) -> MadeAheadPanelStore<Panel> {
        let deadline = MainDeadline(owner: "test.openPanel.release", workClass: .background, scheduler: rig.deadlines)
        return MadeAheadPanelStore(clock: ManualClock(), policy: .afterFirstUse(releaseAfter: releaseAfter, deadline: deadline),
                                   makePanel: { factory.make() }, warmCheck: { .ready })
    }

    /// Whether the rig's one pending wake is the release, `releaseAfter` from now.
    private static func releaseIsDue(_ rig: MainDeadlineRig) -> Bool {
        guard let next = rig.deadlines.nextFire else { return false }
        return next >= releaseAfter && next <= releaseAfter + .seconds(1)
    }

    @Test func theLaunchAndViewWarmUpsMakeNoPanel() {
        let factory = Factory()
        let rig = MainDeadlineRig()
        let store = Self.store(factory, rig: rig)
        store.warmWhenIdle()  // the launch's afterStartup post
        store.warmWhenIdle()  // Home's transcript reaching its window
        #expect(!store.isWarming, "a warm-up was armed before any click")
        #expect(factory.made.isEmpty && !store.isMade, "a panel was made at launch")
        #expect(rig.deadlines.nextFire == nil, "a release was armed with no panel")
    }

    @Test func theClickMakesAndKeepsThePanelThenItIsReleasedOnceUnused() throws {
        let factory = Factory()
        let rig = MainDeadlineRig()
        let store = Self.store(factory, rig: rig)

        let clicked = try #require(store.panel(), "the first click got no panel")
        #expect(factory.made.count == 1 && clicked === factory.made.first)
        #expect(store.isMade, "the first click's panel was not kept for later clicks")
        #expect(Self.releaseIsDue(rig), "no release armed after the click")

        rig.advance(by: .seconds(200))
        #expect(try #require(store.panel()) === clicked, "a second click did not reuse the kept panel")
        #expect(Self.releaseIsDue(rig), "a later click did not push the release back")

        rig.fireAndRun()
        #expect(!store.isMade && store.releasedPanels == 1, "the unused panel was kept past its deadline")
        #expect(rig.deadlines.nextFire == nil)

        // A view reaching a window after the release makes none: the next warm-up waits for the next click.
        store.warmWhenIdle()
        #expect(!store.isWarming && factory.made.count == 1, "a warm-up remade the released panel with no click")
        _ = try #require(store.panel())
        #expect(factory.made.count == 2 && store.isMade, "the click after a release did not make and keep a panel")
    }

    @Test func aPanelShowingItsSheetAtTheDeadlineIsKeptUntilItIsFree() throws {
        let factory = Factory()
        let rig = MainDeadlineRig()
        let store = Self.store(factory, rig: rig)

        let clicked = try #require(store.panel())
        clicked.isFreeForReuse = false  // its sheet shows
        rig.fireAndRun()
        #expect(store.isMade && store.releasedPanels == 0, "a panel whose sheet shows was released")
        #expect(Self.releaseIsDue(rig), "a panel in use at its deadline was not checked again later")

        clicked.isFreeForReuse = true  // the sheet ended
        rig.fireAndRun()
        #expect(!store.isMade && store.releasedPanels == 1, "the panel was kept after its sheet ended and its deadline passed")
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
