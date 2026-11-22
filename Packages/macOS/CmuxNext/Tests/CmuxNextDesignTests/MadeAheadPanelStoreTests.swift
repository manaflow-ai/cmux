@testable import CmuxNextDesign
import Foundation
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

    /// Hands out the panels in `prompts` order (nil: a dead panel), then live ones; counts what it made. Each make
    /// holds the (stand-in) main thread for `takes`: it moves `now`, the clock the store times its makes with, and
    /// adds to `mainThreadWait`, so a test reads what a slow panel service would have cost.
    @MainActor private final class Factory {
        var prompts: [String?]
        var takes: Duration = .milliseconds(120)
        private(set) var made: [Panel] = []
        private(set) var now = ContinuousClock.now
        private(set) var mainThreadWait: Duration = .zero
        /// The test's app defaults, alive as long as the stores that read them.
        var apps: [AppDefaults] = []
        init(_ prompts: [String?]) { self.prompts = prompts }
        /// A proven app (``MadeAheadPanelStoreTests/provenApp()``) kept alive with this factory.
        func proven() -> AppDefaults {
            let app = MadeAheadPanelStoreTests.provenApp()
            apps.append(app)
            return app
        }
        func make() -> Panel {
            now = now.advanced(by: takes)
            mainThreadWait += takes
            let panel = Panel(prompt: prompts.isEmpty ? "Open" : prompts.removeFirst())
            made.append(panel)
            return panel
        }
    }

    /// One app's user defaults, private to the test: every launch of one test's app reads the same record.
    /// Not main-actor isolated, so its deinit can drop the test's defaults domain.
    private nonisolated final class AppDefaults {
        let name = "MadeAheadPanelStoreTests.\(UUID().uuidString)"
        nonisolated(unsafe) let defaults: UserDefaults
        init() { defaults = UserDefaults(suiteName: name)! }
        deinit { defaults.removePersistentDomain(forName: name) }
    }

    /// A launch of the test's app: its own process mark over the app's defaults.
    private static func launch(_ app: AppDefaults, process: String = UUID().uuidString) -> OpenPanelMakeHistory {
        OpenPanelMakeHistory(defaults: app.defaults, process: process)
    }

    /// An app whose earlier launch made a working panel on a click in 300 ms: the service proved fast.
    private static func provenApp() -> AppDefaults {
        let app = AppDefaults()
        let earlier = launch(app)
        earlier.willMake(speculative: false)
        earlier.didMake(took: .milliseconds(300), alive: true, speculative: false)
        return app
    }

    private static func store(_ factory: Factory, clock: ManualClock = ManualClock(), check: OpenPanelWarmCheck = .ready,
                              history: OpenPanelMakeHistory? = nil) -> MadeAheadPanelStore<Panel> {
        MadeAheadPanelStore(clock: clock, makePanel: { factory.make() }, warmCheck: { check },
                            history: history ?? launch(factory.proven()), now: { factory.now })
    }

    /// Runs one warm-up of `store` to its end (none when it schedules no check).
    private static func warm(_ store: MadeAheadPanelStore<Panel>, _ clock: ManualClock) async throws {
        var runs = store.checksRan.makeAsyncIterator()
        store.warmWhenIdle()
        guard store.isWarming else { return }
        try await fire(clock)
        _ = await runs.next()
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
        let store = MadeAheadPanelStore(clock: clock, makePanel: { factory.make() }, warmCheck: { gate.check() },
                                        history: Self.launch(factory.proven()), now: { factory.now })
        var runs = store.checksRan.makeAsyncIterator()
        store.warmWhenIdle()
        try await Self.fire(clock)
        _ = await runs.next()
        #expect(factory.made.isEmpty, "the warm-up made a panel off the console session")
        #expect(!store.isMade && !store.isWarming)
    }

    // MARK: The warm-up on a slow panel service (hang 2dc58e2ab1)

    /// 73 hang reports, each from its own launch: the warm-up's `NSOpenPanel()` waited on a loaded Mac's panel service
    /// inside `-[NSSavePanel _initBridgeAndStuff]` 2 to 60 s on the main thread, at every launch. Here each launch of
    /// one app gets a service that takes 30 s. Only the launch whose record still said "fast" may pay it; every later
    /// launch makes nothing ahead until a click shows the service fast again.
    @Test func aSlowWarmUpStopsTheWarmUpOfEveryLaterLaunch() async throws {
        let app = Self.provenApp()
        let factory = Factory([])
        factory.takes = .seconds(30)
        for launch in 1...4 {
            let clock = ManualClock()
            let store = Self.store(factory, clock: clock, history: Self.launch(app))
            try await Self.warm(store, clock)
            #expect(store.warmChecks == 1, "launch \(launch): the warm-up check never ran")
        }
        #expect(factory.made.count == 1, "\(factory.made.count) of 4 launches made a panel ahead on a 30 s panel service")
        #expect(factory.mainThreadWait == .seconds(30),
                "speculative makes held the main thread \(factory.mainThreadWait) over 4 launches; at most the first 30 s")

        // A click makes its panel anyway; fast now, it proves the service and the next launch warms again.
        factory.takes = .milliseconds(300)
        let clickLaunch = Self.store(factory, history: Self.launch(app))
        #expect(clickLaunch.panel() != nil)
        let clock = ManualClock()
        let next = Self.store(factory, clock: clock, history: Self.launch(app))
        try await Self.warm(next, clock)
        #expect(next.isMade, "a fast click did not bring the warm-up back")
    }

    /// No record (a new app, a new DEV build's bundle): nothing proves the service fast, so the warm-up makes no panel
    /// and the first click makes it.
    @Test func aWarmUpWithNoMakeOnRecordMakesNoPanel() async throws {
        let app = AppDefaults()
        let factory = Factory([])
        let clock = ManualClock()
        let store = Self.store(factory, clock: clock, history: Self.launch(app))
        try await Self.warm(store, clock)
        #expect(store.warmChecks == 1)
        #expect(factory.made.isEmpty, "the warm-up made a panel with nothing proving the panel service fast")
        #expect(store.panel() != nil && factory.made.count == 1, "the click did not make its panel")
    }

    /// A launch quit or killed while its `NSOpenPanel()` held the main thread never wrote how long it took: its
    /// "started" mark reads as slow, so the next launch does not walk into the same wait.
    @Test func aLaunchThatEndedInsideItsMakeStopsTheNextWarmUp() async throws {
        let app = Self.provenApp()
        Self.launch(app).willMake(speculative: true) // and never came back
        let factory = Factory([])
        let clock = ManualClock()
        let store = Self.store(factory, clock: clock, history: Self.launch(app))
        try await Self.warm(store, clock)
        #expect(factory.made.isEmpty, "the warm-up made a panel after a launch ended inside its make")
    }

    /// One speculative make per process, however many stores (and views calling `warmWhenIdle()`) it has.
    @Test func aProcessMakesAtMostOnePanelAhead() async throws {
        let app = Self.provenApp()
        let process = UUID().uuidString
        let factory = Factory([])
        let firstClock = ManualClock()
        let first = Self.store(factory, clock: firstClock, history: Self.launch(app, process: process))
        try await Self.warm(first, firstClock)
        #expect(first.isMade && factory.made.count == 1)
        let secondClock = ManualClock()
        let second = Self.store(factory, clock: secondClock, history: Self.launch(app, process: process))
        try await Self.warm(second, secondClock)
        #expect(!second.isMade && factory.made.count == 1, "a second store of the process made another panel ahead")
    }
}
