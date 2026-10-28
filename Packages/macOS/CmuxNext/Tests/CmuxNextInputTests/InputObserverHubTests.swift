import AppKit
@testable import CmuxNextInput
import CmuxNextWakeups
import Testing

/// The InputObserverHub of p06-scheduler.md B (task 220), which is the app's one input tap
/// (``InputEventTap``): a subscription scoped to a visibility node runs only while its node is not
/// hidden, in every stage, and follows the node's flips in the same turn. With 40 hidden subscribers
/// and one shown, a key-down calls one handler, not 41.
@MainActor @Suite(.serialized)
struct InputObserverHubTests {
    final class Log {
        var calls: [Int] = []
        var open = false
    }

    @Test func fortyHiddenSubscribersAndOneShownRunOneHandlerPerKeyDown() throws {
        let tap = InputEventTap()
        let log = Log()
        let window = VisibilityNode(root: "window", own: .visible)
        let nodes = (0..<41).map { VisibilityNode("tab:\($0)", own: $0 == 40 ? .visible : .hidden, parent: window) }
        let subscriptions = nodes.enumerated().map { index, node in
            tap.subscribe(class: .key, node: node) { _ in log.calls.append(index) }
        }

        try Self.dispatch(Self.key(), through: tap)
        #expect(log.calls == [40], "a key-down ran \(log.calls.count) handlers")

        // Select tab 3: the flip applies to the next event, with no resubscription.
        nodes[40].set(.hidden)
        nodes[3].set(.visible)
        try Self.dispatch(Self.key(), through: tap)
        #expect(log.calls == [40, 3])
        #expect(tap.subscriberCount(.key, stage: .observe) == 41, "a hidden subscriber stays subscribed")
        withExtendedLifetime(subscriptions) {}
    }

    @Test func aHiddenAncestorSilencesTheSubtreeAndOccludedStillHears() throws {
        let tap = InputEventTap()
        let log = Log()
        let window = VisibilityNode(root: "window", own: .visible)
        let pane = VisibilityNode("pane", own: .visible, parent: window)
        let tab = VisibilityNode("tab", own: .visible, parent: pane)
        let subscription = tap.subscribe(class: .key, node: tab) { _ in log.calls.append(0) }

        pane.set(.hidden)
        try Self.dispatch(Self.key(), through: tap)
        #expect(log.calls.isEmpty, "a tab of a suspended pane heard a key")

        pane.set(.visible)
        window.set(.occluded)
        try Self.dispatch(Self.key(), through: tap)
        #expect(log.calls == [0], "a covered key window still types")

        tab.detach()
        try Self.dispatch(Self.key(), through: tap)
        #expect(log.calls == [0], "a detached node is hidden")
        withExtendedLifetime(subscription) {}
    }

    @Test func aHiddenInterceptLetsTheEventPassAndAfterDispatchIsGatedToo() throws {
        let tap = InputEventTap()
        let log = Log()
        let root = VisibilityNode(root: "window", own: .visible)
        let node = VisibilityNode("tab", own: .hidden, parent: root)
        let intercept = tap.subscribe(class: .key, phase: .intercept(order: .standard), node: node) { _ in
            log.calls.append(1)
            return .consume
        }
        let after = tap.subscribe(class: .key, phase: .afterDispatch, node: node) { _ in log.calls.append(2) }

        #expect(try !Self.dispatch(Self.key(), through: tap), "a hidden intercept consumed a key")
        #expect(log.calls.isEmpty)

        node.set(.visible)
        #expect(try Self.dispatch(Self.key(), through: tap))
        #expect(log.calls == [1, 2])
        withExtendedLifetime((intercept, after)) {}
    }

    @Test func theNodeAndTheWhilePredicateBothGate() throws {
        let tap = InputEventTap()
        let log = Log()
        let root = VisibilityNode(root: "window", own: .visible)
        let subscription = tap.subscribe(class: .key, node: root, while: { log.open }) { _ in log.calls.append(0) }

        try Self.dispatch(Self.key(), through: tap)
        log.open = true
        root.set(.hidden)
        try Self.dispatch(Self.key(), through: tap)
        #expect(log.calls.isEmpty)
        root.set(.visible)
        try Self.dispatch(Self.key(), through: tap)
        #expect(log.calls == [0])
        withExtendedLifetime(subscription) {}
    }

    // MARK: helpers

    /// Runs `event` through the tap as `CmuxApplication.sendEvent` does; true when an intercept consumed it.
    @discardableResult
    private static func dispatch(_ event: NSEvent, through tap: InputEventTap) -> Bool {
        var consumed = false
        tap.dispatching {
            tap.deliverObserve(event)
            consumed = tap.deliverIntercepts(event) == .consume
            tap.deliverAfterDispatch(event)
        }
        return consumed
    }

    private static func key() throws -> NSEvent {
        _ = NSApplication.shared
        return try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1,
                                             windowNumber: 0, context: nil, characters: "a",
                                             charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
    }
}
