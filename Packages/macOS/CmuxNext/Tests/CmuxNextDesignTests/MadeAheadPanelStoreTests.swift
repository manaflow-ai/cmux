@testable import CmuxNextDesign
import Testing
import CmuxNextWakeupsTestSupport

/// With no GUI session (a fleet worker whose account is not the console user, 2026-10-23) `NSOpenPanel()` blocks
/// the main thread about 40 s on ViewBridge, then comes back with a nil prompt: a dead panel. The made-ahead
/// store drops it, and must also remember that the warm-up failed: each agent chat or Home view that reaches a
/// window calls `warmWhenIdle()`, and a store that forgot armed a new warm-up, and a new 40 s block, every time.
/// These panels stand in for `NSOpenPanel`, which this test host cannot make without its view service.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct MadeAheadPanelStoreTests {
    @MainActor private final class Panel: ReusableOpenPanel {
        var openPanelPrompt: String?
        var openPanelMessage: String?
        var isFreeForReuse = true
        var resets = 0
        init(prompt: String?) {
            openPanelPrompt = prompt
            openPanelMessage = prompt == nil ? nil : ""
        }
        func setOpenPanelTexts(prompt: String, message: String) {
            openPanelPrompt = prompt
            openPanelMessage = message
        }
        func resetChoices() { resets += 1 }
    }

    /// Hands out the panels in `prompts` order (nil: a dead panel), then live ones; counts what it made.
    @MainActor private final class Factory {
        var prompts: [String?]
        private(set) var made: [Panel] = []
        init(_ prompts: [String?]) { self.prompts = prompts }
        func make() -> Panel {
            let panel = Panel(prompt: prompts.isEmpty ? "Open" : prompts.removeFirst())
            made.append(panel)
            return panel
        }
    }

    /// Makes working panels and keeps no strong reference to them: `alive` counts the ones that some owner still
    /// holds. The app's `NSOpenPanel` stands behind each: while one is alive, its panel service
    /// (`com.apple.appkit.xpc.openAndSavePanelService`) keeps the folder it shows in sync on every file-system event.
    @MainActor private final class LivePanels {
        private final class Ref {
            weak var panel: Panel?
            init(_ panel: Panel) { self.panel = panel }
        }
        private var refs: [Ref] = []
        /// The panels made so far.
        var made: Int { refs.count }
        /// The panels made that are still alive.
        var alive: Int { refs.filter { $0.panel != nil }.count }
        func make() -> Panel {
            let panel = Panel(prompt: "Open")
            refs.append(Ref(panel))
            return panel
        }
    }

    /// One pick from the click to its end: the caller takes the panel, shows it, and lets it go when its handler ran.
    private static func pickAndEnd(_ store: MadeAheadPanelStore<Panel>) -> Bool {
        store.panel() != nil
    }

    private static func store(_ factory: Factory, clock: ManualClock = ManualClock(),
                              check: OpenPanelWarmCheck = .ready) -> MadeAheadPanelStore<Panel> {
        MadeAheadPanelStore(clock: clock, makePanel: { factory.make() }, warmCheck: { check })
    }

    /// Fires the pending warm-up check. The test then awaits the check's end on its one local iterator of
    /// ``MadeAheadPanelStore/checksRan`` (`await runs.next()`, as MachineCatalogPublisherTests reads its stream; an
    /// iterator passed `inout` through a main-actor helper would cross isolation), bounded by the suite's time limit.
    private static func fire(_ clock: ManualClock) async throws {
        try await clock.waitForSleeper()
        clock.advance(by: .seconds(2))
    }

    @Test func aWarmUpThatGotADeadPanelKeepsNoneAndArmsNoOtherWarmUp() async throws {
        let factory = Factory([nil])
        let clock = ManualClock()
        let store = Self.store(factory, clock: clock)
        var runs = store.checksRan.makeAsyncIterator()
        store.warmWhenIdle()
        #expect(store.isWarming)
        try await Self.fire(clock)
        _ = await runs.next()
        #expect(store.warmChecks == 1, "the warm-up check never ran")
        #expect(factory.made.count == 1)
        #expect(!store.isMade, "a panel whose view service never answered was kept")

        // The next chat or Home view in a window: no new warm-up, so no second NSOpenPanel() on the main thread.
        store.warmWhenIdle()
        #expect(!store.isWarming, "a warm-up that got a dead panel armed another one")
        if store.isWarming {
            try await Self.fire(clock)
            _ = await runs.next()
        }
        #expect(factory.made.count == 1, "the warm-up made another panel after the first came back dead")
    }

    @Test func aClickAfterADeadWarmUpGetsAFreshPanelAndKeepsItWhenItWorks() async throws {
        let factory = Factory([nil])
        let clock = ManualClock()
        let store = Self.store(factory, clock: clock)
        var runs = store.checksRan.makeAsyncIterator()
        store.warmWhenIdle()
        try await Self.fire(clock)
        _ = await runs.next()
        #expect(!store.isMade)

        let clicked = try #require(store.panel(), "a working panel made on the click was not handed out")
        #expect(factory.made.count == 2, "the click did not make a new panel")
        #expect(clicked === factory.made.last)
        #expect(store.isMade, "a working panel made on the click was not kept")
        // Once a working panel is kept, a free one is reused with a new panel's choices and its own texts.
        clicked.setOpenPanelTexts(prompt: "Attach", message: "Choose files")
        let again = try #require(store.panel())
        #expect(again === clicked && factory.made.count == 2)
        #expect(again.resets == 1 && again.openPanelPrompt == "Open" && again.openPanelMessage == "")
    }

    /// A dead panel is never handed out: `AgentPaneFilePicker` awaits `beginSheetModal`'s handler in a continuation,
    /// and a dead panel's sheet may never call it, so the attach flow would hang (review 2 of pl-fleet-gui).
    @Test func aDeadPanelFromAClickIsNotKeptOrHandedOut() {
        let factory = Factory([nil, nil])
        let store = Self.store(factory)
        #expect(store.panel() == nil, "a dead panel was handed out to a click")
        #expect(!store.isMade)
        #expect(store.panel() == nil, "a dead panel was handed out to the next click")
        #expect(factory.made.count == 2, "each click makes its own panel")
        #expect(!store.isMade)
        store.warmWhenIdle()
        #expect(!store.isWarming, "a dead panel on the click still armed a warm-up")
    }

    @Test func aProcessThatCannotMakeAPanelMakesNoneAndEndsTheWarmUp() async throws {
        let factory = Factory([])
        let clock = ManualClock()
        let store = Self.store(factory, clock: clock, check: .never(reason: "test host"))
        var runs = store.checksRan.makeAsyncIterator()
        store.warmWhenIdle()
        try await Self.fire(clock)
        _ = await runs.next()
        #expect(factory.made.isEmpty && !store.isMade && !store.isWarming)
    }

    /// The app's gate in a running app whose account is not the console user (an app started over SSH or by a fleet
    /// worker): the warm-up makes no panel, so no `NSOpenPanel()` blocks the main thread about 40 s on ViewBridge.
    @Test func aRunningAppOffTheConsoleSessionMakesNoPanel() async throws {
        let gate = OpenPanelWarmGate(appIsRunning: { true }, sessionIsOnConsole: { false }, personIsIdle: { true })
        let factory = Factory([])
        let clock = ManualClock()
        let store = MadeAheadPanelStore(clock: clock, makePanel: { factory.make() }, warmCheck: { gate.check() })
        var runs = store.checksRan.makeAsyncIterator()
        store.warmWhenIdle()
        try await Self.fire(clock)
        _ = await runs.next()
        #expect(factory.made.isEmpty, "the warm-up made a panel off the console session")
        #expect(!store.isMade && !store.isWarming)
    }

    /// At rest the app keeps no open panel alive. A live `NSOpenPanel` cost Lawrence's Mac 2.8 to 4.8 % of a core
    /// for the life of each app (2026-11-10): its panel service ran DesktopServicesPriv `TNode::SynchronizeChildren`
    /// for the shown folder on each file-system event. The warm-up pays the process's first panel and lets it go.
    @Test func theWarmUpLeavesNoPanelAlive() async throws {
        let live = LivePanels()
        let clock = ManualClock()
        let store = MadeAheadPanelStore(clock: clock, makePanel: { live.make() }, warmCheck: { .ready })
        var runs = store.checksRan.makeAsyncIterator()
        store.warmWhenIdle()
        try await Self.fire(clock)
        _ = await runs.next()
        #expect(live.made == 1, "the warm-up made no panel: the first click pays the process's first panel")
        #expect(live.alive == 0, "the warm-up's panel is still alive at rest: its panel service keeps a folder in sync")
    }

    /// The same after a pick: when its sheet ended and the caller let the panel go, the store holds none.
    @Test func aPickThatEndedLeavesNoPanelAlive() {
        let live = LivePanels()
        let store = MadeAheadPanelStore(clock: ManualClock(), makePanel: { live.make() }, warmCheck: { .ready })
        #expect(Self.pickAndEnd(store), "a working panel made on the click was not handed out")
        #expect(live.made == 1)
        #expect(live.alive == 0, "the panel of a pick that ended is still alive at rest")
    }
}
