@testable import CmuxNextDesign
import Testing

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

    private static func store(_ factory: Factory, clock: ThinScrollerManualClock = ThinScrollerManualClock(),
                              check: OpenPanelWarmCheck = .ready) -> MadeAheadPanelStore<Panel> {
        MadeAheadPanelStore(clock: clock, makePanel: { factory.make() }, warmCheck: { check })
    }

    /// Fires the pending warm-up check and waits (bounded) until it ran on the main actor.
    private static func fire(_ store: MadeAheadPanelStore<Panel>, _ clock: ThinScrollerManualClock) async throws {
        let checks = store.warmChecks
        try await clock.waitForSleeper()
        clock.advance(by: .seconds(2))
        for _ in 0..<500 where store.warmChecks == checks { try await Task.sleep(for: .milliseconds(5)) }  // bounded
        #expect(store.warmChecks == checks + 1, "the warm-up check never ran")
    }

    @Test func aWarmUpThatGotADeadPanelKeepsNoneAndArmsNoOtherWarmUp() async throws {
        let factory = Factory([nil])
        let clock = ThinScrollerManualClock()
        let store = Self.store(factory, clock: clock)
        store.warmWhenIdle()
        #expect(store.isWarming)
        try await Self.fire(store, clock)
        #expect(factory.made.count == 1)
        #expect(!store.isMade, "a panel whose view service never answered was kept")

        // The next chat or Home view in a window: no new warm-up, so no second NSOpenPanel() on the main thread.
        store.warmWhenIdle()
        #expect(!store.isWarming, "a warm-up that got a dead panel armed another one")
        if store.isWarming { try await Self.fire(store, clock) }
        #expect(factory.made.count == 1, "the warm-up made another panel after the first came back dead")
    }

    @Test func aClickAfterADeadWarmUpGetsAFreshPanelAndKeepsItWhenItWorks() async throws {
        let factory = Factory([nil])
        let clock = ThinScrollerManualClock()
        let store = Self.store(factory, clock: clock)
        store.warmWhenIdle()
        try await Self.fire(store, clock)
        #expect(!store.isMade)

        let clicked = store.panel()
        #expect(factory.made.count == 2, "the click did not make a new panel")
        #expect(clicked === factory.made.last)
        #expect(store.isMade, "a working panel made on the click was not kept")
        // Once a working panel is kept, a free one is reused with a new panel's choices and its own texts.
        clicked.setOpenPanelTexts(prompt: "Attach", message: "Choose files")
        let again = store.panel()
        #expect(again === clicked && factory.made.count == 2)
        #expect(again.resets == 1 && again.openPanelPrompt == "Open" && again.openPanelMessage == "")
    }

    @Test func aDeadPanelFromAClickIsNotKeptOrHandedOutAgain() {
        let factory = Factory([nil, nil])
        let store = Self.store(factory)
        let first = store.panel()
        #expect(!store.isMade)
        let second = store.panel()
        #expect(second !== first, "a dead panel was handed out again")
        #expect(!store.isMade)
        store.warmWhenIdle()
        #expect(!store.isWarming, "a dead panel on the click still armed a warm-up")
    }

    @Test func aProcessThatCannotMakeAPanelMakesNoneAndEndsTheWarmUp() async throws {
        let factory = Factory([])
        let clock = ThinScrollerManualClock()
        let store = Self.store(factory, clock: clock, check: .never)
        store.warmWhenIdle()
        try await Self.fire(store, clock)
        #expect(factory.made.isEmpty && !store.isMade && !store.isWarming)
    }
}
