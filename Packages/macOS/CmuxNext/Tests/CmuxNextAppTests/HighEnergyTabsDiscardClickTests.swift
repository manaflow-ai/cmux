import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDesign
import CmuxNextInput
@testable import CmuxNextTabs
import CmuxNextWakeupsTestSupport
import Testing

/// Discard in a high-energy tab's card runs when the person clicks it. The press goes through the app's
/// input tap first, where the card's dismissal observer hears every press before AppKit hands it on: a press on a card
/// that takes clicks must leave the card up, so AppKit hands it to Discard, whose action discards the tab and ends the
/// card. With motion off, a card the observer dismissed is already ordered out when AppKit would hand on the press.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct HighEnergyTabsDiscardClickTests {
    /// Says every tab uses high energy and records each Discard.
    @MainActor final class Energy: TabEnergySource {
        var discarded: [TabID] = []
        func usesHighEnergy(_ tab: TabID, changed: @escaping @MainActor () -> Void) -> Bool { true }
        func discard(_ tab: TabID) { discarded.append(tab) }
    }

    /// Lets a deadline the clock reached reach the coordinator (the timer wakes off the main actor and hops back),
    /// waiting (bounded) for `done`.
    private static func settle(until done: () -> Bool) async throws {
        for _ in 0..<20 { await Task.yield() }
        for _ in 0..<500 where !done() { try await Task.sleep(for: .milliseconds(10)) }
    }

    private static func cardBody(in view: NSView) -> TabHoverCardView? {
        if let body = view as? TabHoverCardView { return body }
        return view.subviews.lazy.compactMap(cardBody(in:)).first
    }

    @Test func aClickOnDiscardGoesThroughTheTapToTheButton() async throws {
        _ = NSApplication.shared
        let design = DesignSettings.shared
        let speed = design.animationSpeed
        design.animationSpeed = .off
        defer { design.animationSpeed = speed }

        let tabs = ["a", "b"].map { TabItem(id: TabID($0), title: "Tab \($0)", subtitle: "https://example.com/\($0)") }
        let strip = TabStripView.testing(model: TabStripModel(tabs: tabs, selectedID: TabID("a")))
        let window = NSWindow(contentRect: NSRect(x: 200, y: 400, width: 700, height: 300), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let clock = ManualClock()
        let tap = InputEventTap()
        let coordinator = HoverCardCoordinator(clock: clock, input: tap)
        coordinator.appIsActive = { true }
        coordinator.hoverCardsEnabled = { true }
        coordinator.mouseButtonDown = { false }
        coordinator.windowNumberAt = { [weak window] _ in window?.windowNumber }
        coordinator.pointerLocation = { .zero }
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 300))
        window.contentView = content
        strip.frame = NSRect(x: 0, y: 300 - TabStripView.preferredHeight, width: 700, height: TabStripView.preferredHeight)
        content.addSubview(strip)
        strip.hoverCards = coordinator
        let energy = Energy()
        strip.hoverCard.energy = energy
        window.orderFrontRegardless()
        strip.layoutSubtreeIfNeeded()
        defer {
            coordinator.dismiss(.action)
            while NSApp.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true) != nil {}
            window.contentView = nil
            window.close()
        }

        // Rest on the hidden tab until its card shows, with the energy row and Discard.
        let cell = try #require(strip.cells[TabID("b")])
        strip.updateHover(at: strip.convert(CGPoint(x: cell.frame.midX, y: cell.frame.midY), from: strip.tabsClip), moved: true)
        try await clock.waitForSleeper()
        clock.advance(by: design.hoverCardDelay + .milliseconds(100))
        let card = TabHoverCardController.targetID(TabID("b"))
        try await Self.settle(until: { coordinator.isShowing(card) })
        try #require(coordinator.isShowing(card), "resting on the tab showed no card")
        let panel = try #require(coordinator.panel)
        try #require(panel.isInteractive, "a card with Discard lets clicks through")
        let body = try #require(panel.contentView.flatMap(Self.cardBody(in:)), "the card shows no tab body")
        try #require(body.offersDiscard, "the card offers no Discard")
        body.layoutSubtreeIfNeeded()
        let button = body.discardButton
        let point = button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                            pressure: type == .leftMouseUp ? 0 : 1))
        }

        // The press as the app dispatches it: the tap's stages around AppKit's own `sendEvent`, with the release
        // queued for the button's tracking loop.
        NSApp.postEvent(try event(.leftMouseUp), atStart: false)
        var cardTookThePress = false
        let result = CmuxApplication.dispatchThroughTap(try event(.leftMouseDown), tap: tap) { press in
            cardTookThePress = panel.isShowingCard && panel.isInteractive
            NSApp.sendEvent(press)
        }
        #expect(result == .pass)
        #expect(cardTookThePress, "the press on Discard ended its own card before AppKit handed it on")
        #expect(energy.discarded == [TabID("b")], "Discard did not discard the tab: \(energy.discarded)")
        #expect(coordinator.machine.shownTarget == nil, "Discard left its card up")
    }
}
