import AppKit
import Foundation
import Testing
@testable import CmuxNextAgentPane
@testable import CmuxNextInput
import CmuxNextWakeups

/// A subagent open's watch for the person's next action goes through the app's input tap:
/// one press subscription, held only while a focus is owed, that hears key-downs and
/// mouse-downs in any window and nothing else, and leaves the tap when the watch stops.
@Suite(.serialized)
@MainActor
struct AgentSubagentPanesTests {
    final class Counter {
        var acted = 0
    }

    private static func dispatch(_ event: NSEvent, through tap: InputEventTap) {
        tap.dispatching {
            tap.deliverObserve(event)
            _ = tap.deliverIntercepts(event)
            tap.deliverAfterDispatch(event)
        }
    }

    private static func key(_ type: NSEvent.EventType) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: 0, context: nil, characters: "a", charactersIgnoringModifiers: "a",
                                      isARepeat: false, keyCode: 0))
    }

    private static func mouse(_ type: NSEvent.EventType) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    private static func liveSubscriptions(_ tap: InputEventTap) -> Int {
        InputEventClass.allCases.reduce(0) { total, eventClass in
            total + [InputEventTap.Stage.observe, .intercept, .afterDispatch].reduce(0) { $0 + tap.subscriberCount(eventClass, stage: $1) }
        }
    }

    @Test func theWatchHearsPressesOnlyAndLeavesTheTapWhenStopped() throws {
        let tap = InputEventTap()
        let counter = Counter()
        let stop = AgentSubagentPanes.watchUser(on: tap, appEvents: AppEvents(center: NotificationCenter()))({ counter.acted += 1 })
        #expect(tap.subscriberCount(.key, stage: .intercept) == 1)
        #expect(tap.subscriberCount(.button, stage: .intercept) == 1)
        #expect(tap.subscriberCount(.key, stage: .observe) == 0, "the watch hears presses after the key router, not before it")

        Self.dispatch(try Self.key(.keyUp), through: tap)
        Self.dispatch(try Self.mouse(.leftMouseUp), through: tap)
        #expect(counter.acted == 0, "an up is not the person's next action")
        Self.dispatch(try Self.key(.keyDown), through: tap)
        Self.dispatch(try Self.mouse(.rightMouseDown), through: tap)
        #expect(counter.acted == 2)

        stop()
        #expect(Self.liveSubscriptions(tap) == 0, "a stopped watch left a subscription on the tap")
        Self.dispatch(try Self.key(.keyDown), through: tap)
        #expect(counter.acted == 2, "a stopped watch still heard a key")
    }

    /// The watch runs where the AppKit local monitor it replaced ran, after the key router: a press
    /// that an app shortcut or an earlier intercept (a modal, a popup) consumed is not the person's
    /// next action, so the focus stays owed; a press that reaches the watch is.
    @Test func aPressAnEarlierInterceptConsumedLeavesTheFocusOwed() throws {
        let tap = InputEventTap()
        let counter = Counter()
        let stop = AgentSubagentPanes.watchUser(on: tap, appEvents: AppEvents(center: NotificationCenter()))({ counter.acted += 1 })
        defer { stop() }
        let modal = tap.subscribe(class: [.key, .button], phase: .intercept(order: .modal)) { _ in .consume }
        Self.dispatch(try Self.key(.keyDown), through: tap)
        Self.dispatch(try Self.mouse(.leftMouseDown), through: tap)
        #expect(counter.acted == 0, "a press a modal consumed counted as the person's next action")

        modal.cancel()
        Self.dispatch(try Self.key(.keyDown), through: tap)
        #expect(counter.acted == 1, "a press that reached the watch did not count")
    }

    @Test func aWindowTakingTheKeyboardIsAnActionToo() {
        let tap = InputEventTap()
        let center = NotificationCenter()
        let counter = Counter()
        let appEvents = AppEvents(center: center)  // the app holds its one AppEvents for its lifetime
        let stop = AgentSubagentPanes.watchUser(on: tap, appEvents: appEvents)({ counter.acted += 1 })
        center.post(name: NSWindow.didBecomeKeyNotification, object: nil)
        center.post(name: NSApplication.didResignActiveNotification, object: nil)
        #expect(counter.acted == 2)
        // Two watches share the app's one observer per notice (R-notif), not one each.
        let second = AgentSubagentPanes.watchUser(on: tap, appEvents: appEvents)({})
        #expect(appEvents.subscriberCount(NSWindow.didBecomeKeyNotification) == 2)
        center.post(name: NSWindow.didBecomeKeyNotification, object: nil)
        #expect(appEvents.deliveries(NSWindow.didBecomeKeyNotification) == 2)
        #expect(counter.acted == 3)
        second()
        stop()
        #expect(!appEvents.isObserving(NSWindow.didBecomeKeyNotification), "the last watch's stop removes the observer")
        center.post(name: NSWindow.didBecomeKeyNotification, object: nil)
        #expect(counter.acted == 3)
    }

    /// End to end with the tracker: the watch is on the tap only while a focus is owed, and the
    /// person's click through the tap drops the owed focus and the watch.
    @Test func anOwedFocusHoldsTheWatchUntilThePersonActs() throws {
        let tap = InputEventTap()
        let panes = AgentSubagentPanes()
        var focused: [String] = []
        var open: Set<String> = []
        var finished: (@MainActor (Bool) -> Void)?
        let hooks = AgentSubagentPanes.Hooks(
            isOpen: { open.contains($0) },
            focus: { key, _ in focused.append(key) },
            place: { _, _, _, done in
                finished = done
                return true
            },
            again: { _ in },
            watchUser: AgentSubagentPanes.watchUser(on: tap, appEvents: AppEvents(center: NotificationCenter())))

        #expect(panes.open("explore", focus: false, chat: "chat", hooks: hooks))
        #expect(Self.liveSubscriptions(tap) == 0, "nothing is owed yet, so nothing watches")
        #expect(panes.open("explore", focus: true, chat: "chat", hooks: hooks))
        #expect(tap.subscriberCount(.button, stage: .intercept) == 1, "an owed focus watches for the person's next press")

        Self.dispatch(try Self.mouse(.leftMouseDown), through: tap)
        #expect(Self.liveSubscriptions(tap) == 0, "the person acted: the watch left the tap")
        open.insert("tab-explore")
        panes.record("explore", tab: "tab-explore")
        finished?(true)
        #expect(focused.isEmpty, "the owed focus landed after the person acted")
    }
}
