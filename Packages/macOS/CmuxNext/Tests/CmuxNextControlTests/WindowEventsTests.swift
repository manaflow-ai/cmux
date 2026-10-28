import AppKit
import CmuxNextWakeups
import Testing

/// WindowEvents and AppEvents (architecture-refactor-DESIGN.md row B): one
/// NotificationCenter observer per window or app per name, made on the first subscriber and
/// removed with the last; hidden subscribers get no call per post and one missed call on show.
@MainActor @Suite(.timeLimit(.minutes(1))) struct WindowEventsTests {
    private static let name = Notification.Name("WindowEventsTests.changed")
    private static let other = Notification.Name("WindowEventsTests.other")

    private static func window() -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    @Test func aHundredSubscribersShareOneObserverPerName() {
        let center = NotificationCenter()
        let window = Self.window()
        let events = WindowEvents(window: window, center: center)
        let node = VisibilityNode(root: "window", own: .visible)
        var calls: [Notification.Name: Int] = [:]
        var tokens: [EventSubscription] = []
        for name in [Self.name, Self.other] {
            for _ in 0..<100 {
                tokens.append(events.subscribe(name, node: node, delivery: .whenVisible, owner: "view") { call in
                    #expect(call == .posted)
                    calls[name, default: 0] += 1
                })
            }
        }
        #expect(events.isObserving(Self.name) && events.isObserving(Self.other))
        #expect(events.subscriberCount(Self.name) == 100)
        center.post(name: Self.name, object: window)
        // One delivery from the center fans out to the 100 subscribers.
        #expect(events.deliveries(Self.name) == 1)
        #expect(calls[Self.name] == 100)
        #expect(calls[Self.other] == nil)
        _ = tokens
    }

    @Test func hiddenSubscribersGetNoCallsThenOneMissedCallOnShow() {
        let center = NotificationCenter()
        let events = AppEvents(center: center)
        let window = VisibilityNode(root: "window", own: .visible)
        let tab = VisibilityNode("tab", own: .hidden, parent: window)
        var calls: [EventCall] = []
        let tokens = (0..<10).map { _ in
            events.subscribe(Self.name, node: tab, delivery: .whenVisible, owner: "tab") { calls.append($0) }
        }
        for _ in 0..<5 { center.post(name: Self.name, object: nil) }
        #expect(calls.isEmpty)
        tab.set(.visible)
        #expect(calls == Array(repeating: .missed, count: 10))
        // Shown again with nothing posted while hidden: no missed call.
        calls.removeAll()
        tab.set(.hidden)
        tab.set(.visible)
        #expect(calls.isEmpty)
        center.post(name: Self.name, object: nil)
        #expect(calls == Array(repeating: .posted, count: 10))
        _ = tokens
    }

    @Test func anOccludedSubscriberWaitsForVisible() {
        let center = NotificationCenter()
        let events = AppEvents(center: center)
        let window = VisibilityNode(root: "window", own: .occluded)
        var calls: [EventCall] = []
        let token = events.subscribe(Self.name, node: window, delivery: .whenVisible, owner: "indicator") { calls.append($0) }
        center.post(name: Self.name, object: nil)
        #expect(calls.isEmpty)
        window.set(.visible)
        #expect(calls == [.missed])
        _ = token
    }

    /// A capture vote makes a hidden node render (a screenshot of a hidden tab draws
    /// its views), so its whenVisible subscribers hear what they missed in the vote's turn and every
    /// post while the vote holds, with page visibility still hidden; after the release they wait again.
    @Test func aCapturedHiddenSubscriberHearsPostsWhileTheVoteHolds() {
        let center = NotificationCenter()
        let events = AppEvents(center: center)
        let window = VisibilityNode(root: "window", own: .visible)
        let tab = VisibilityNode("tab", own: .hidden, parent: window)
        var calls: [EventCall] = []
        let token = events.subscribe(Self.name, node: tab, delivery: .whenVisible, owner: "tab") { calls.append($0) }
        center.post(name: Self.name, object: nil)
        #expect(calls.isEmpty)
        let vote = tab.captureVote(reason: "agent.screenshot", stayHidden: true)
        #expect(tab.effective == .hidden && tab.wantsFrames)
        #expect(calls == [.missed], "the capture drew a view that missed a post")
        center.post(name: Self.name, object: nil)
        #expect(calls == [.missed, .posted], "a post to a captured view waited for a show")
        vote.release()
        center.post(name: Self.name, object: nil)
        #expect(calls == [.missed, .posted], "a released node did view work")
        tab.set(.visible)
        #expect(calls == [.missed, .posted, .missed])
        _ = token
    }

    @Test func alwaysSubscribersHearEveryPostWhileHidden() {
        let center = NotificationCenter()
        let events = AppEvents(center: center)
        let node = VisibilityNode(root: "window", own: .hidden)
        var calls: [EventCall] = []
        let token = events.subscribe(Self.name, node: node, delivery: .always, owner: "capture") { calls.append($0) }
        center.post(name: Self.name, object: nil)
        center.post(name: Self.name, object: nil)
        node.set(.visible)
        #expect(calls == [.posted, .posted])
        _ = token
    }

    @Test func theLastUnsubscribeRemovesTheObserver() {
        let center = NotificationCenter()
        let events = AppEvents(center: center)
        let node = VisibilityNode(root: "app", own: .visible)
        var calls = 0
        let first = events.subscribe(Self.name, node: node, delivery: .whenVisible, owner: "a") { _ in calls += 1 }
        var second: EventSubscription? = events.subscribe(Self.name, node: node, delivery: .whenVisible, owner: "b") { _ in calls += 1 }
        first.cancel()
        #expect(events.isObserving(Self.name))
        #expect(events.subscriberCount(Self.name) == 1)
        // Releasing the token ends it as cancel() does.
        second = nil
        #expect(!events.isObserving(Self.name))
        center.post(name: Self.name, object: nil)
        #expect(events.deliveries(Self.name) == 0)
        #expect(calls == 0)
        // A new subscriber makes the observer again.
        let third = events.subscribe(Self.name, node: node, delivery: .whenVisible, owner: "c") { _ in calls += 1 }
        center.post(name: Self.name, object: nil)
        #expect(events.deliveries(Self.name) == 1 && calls == 1)
        _ = (second, third)
    }

    @Test func aCancelledHiddenSubscriberGetsNoMissedCall() {
        let center = NotificationCenter()
        let events = AppEvents(center: center)
        let node = VisibilityNode(root: "workspace", own: .hidden)
        var calls = 0
        let token = events.subscribe(Self.name, node: node, delivery: .whenVisible, owner: "row") { _ in calls += 1 }
        center.post(name: Self.name, object: nil)
        #expect(node.deferredCount == 1)
        token.cancel()
        #expect(node.deferredCount == 0)
        node.set(.visible)
        #expect(calls == 0)
    }

    @Test func windowEventsHearOnlyTheirWindow() {
        let center = NotificationCenter()
        let window = Self.window(), other = Self.window()
        let events = WindowEvents(window: window, center: center)
        var calls = 0
        let token = events.subscribe(Self.name, owner: "tracker") { calls += 1 }
        center.post(name: Self.name, object: other)
        center.post(name: Self.name, object: nil)
        #expect(calls == 0)
        center.post(name: Self.name, object: window)
        #expect(calls == 1)
        _ = token
    }

    @Test func ofKeepsOneInstancePerWindow() {
        let center = NotificationCenter()
        let window = Self.window(), other = Self.window()
        #expect(WindowEvents.of(window, center: center) === WindowEvents.of(window, center: center))
        #expect(WindowEvents.of(window, center: center) !== WindowEvents.of(other, center: center))
    }

    @Test func subscribersAreCalledInTheOrderTheySubscribed() {
        let center = NotificationCenter()
        let events = AppEvents(center: center)
        let shown = VisibilityNode(root: "window", own: .visible)
        let tab = VisibilityNode("tab", own: .hidden, parent: shown)
        var calls: [String] = []
        // Enough subscribers that a hash order would differ from the subscription order.
        let names = (0..<64).map { "s\($0)" }
        let tokens = names.map { owner in
            events.subscribe(Self.name, node: tab, delivery: .whenVisible, owner: owner) { call in
                calls.append("\(owner):\(call == .posted ? "posted" : "missed")")
            }
        }
        // A cancelled one leaves a hole; the rest keep their order through compaction.
        for index in names.indices where index % 4 != 0 { tokens[index].cancel() }
        let kept = names.enumerated().filter { $0.offset % 4 == 0 }.map(\.element)
        center.post(name: Self.name, object: nil)
        tab.set(.visible)
        #expect(calls == kept.map { "\($0):missed" })
        calls.removeAll()
        center.post(name: Self.name, object: nil)
        #expect(calls == kept.map { "\($0):posted" })
        _ = tokens
    }

    @Test func missedCallsAcrossNamesComeInTheOrderTheyWereMissed() {
        let center = NotificationCenter()
        let events = AppEvents(center: center)
        let node = VisibilityNode(root: "workspace", own: .hidden)
        var calls: [String] = []
        let a = events.subscribe(Self.name, node: node, delivery: .whenVisible, owner: "a") { _ in calls.append("a") }
        let b = events.subscribe(Self.other, node: node, delivery: .whenVisible, owner: "b") { _ in calls.append("b") }
        center.post(name: Self.other, object: nil)
        center.post(name: Self.name, object: nil)
        node.set(.visible)
        #expect(calls == ["b", "a"])
        _ = (a, b)
    }

    @Test func postsWhileHiddenAddNoWorkAfterTheFirst() {
        let center = NotificationCenter()
        let events = AppEvents(center: center)
        let node = VisibilityNode(root: "workspace", own: .hidden)
        var calls = 0
        let tokens = (0..<100).map { _ in
            events.subscribe(Self.name, node: node, delivery: .whenVisible, owner: "row") { _ in calls += 1 }
        }
        center.post(name: Self.name, object: nil)
        // One deferred call for the node, not one per subscriber.
        #expect(node.deferredCount == 1)
        #expect(events.deferredWork == 1)
        for _ in 0..<5 { center.post(name: Self.name, object: nil) }
        #expect(node.deferredCount == 1)
        #expect(events.deferredWork == 1)
        #expect(calls == 0)
        node.set(.visible)
        #expect(calls == 100)
        #expect(node.deferredCount == 0)
        // Hidden again: the next post hands the node one new deferred call.
        node.set(.hidden)
        center.post(name: Self.name, object: nil)
        #expect(events.deferredWork == 2)
        _ = tokens
    }

    @Test func aMissedHandlerThatHidesTheNodeLeavesTheRestForTheNextShow() {
        let center = NotificationCenter()
        let events = AppEvents(center: center)
        let node = VisibilityNode(root: "workspace", own: .hidden)
        var calls: [String] = []
        let a = events.subscribe(Self.name, node: node, delivery: .whenVisible, owner: "a") { _ in
            calls.append("a")
            node.set(.hidden)
        }
        let b = events.subscribe(Self.name, node: node, delivery: .whenVisible, owner: "b") { _ in calls.append("b") }
        center.post(name: Self.name, object: nil)
        node.set(.visible)
        #expect(calls == ["a"])
        #expect(node.deferredCount == 1)
        node.set(.visible)
        #expect(calls == ["a", "b"])
        #expect(node.deferredCount == 0)
        _ = (a, b)
    }

    @Test func cancellingOneOfSeveralMissedSubscribersKeepsTheOthersCall() {
        let center = NotificationCenter()
        let events = AppEvents(center: center)
        let node = VisibilityNode(root: "workspace", own: .hidden)
        var calls: [String] = []
        let a = events.subscribe(Self.name, node: node, delivery: .whenVisible, owner: "a") { _ in calls.append("a") }
        let b = events.subscribe(Self.name, node: node, delivery: .whenVisible, owner: "b") { _ in calls.append("b") }
        center.post(name: Self.name, object: nil)
        a.cancel()
        #expect(node.deferredCount == 1)
        node.set(.visible)
        #expect(calls == ["b"])
        _ = b
    }

    @Test func theFamilyIsTheWindowAndTheWindowsItOwns() {
        final class Window {
            let parent: Window?
            init(parent: Window? = nil) { self.parent = parent }
        }
        let shell = Window(), page = Window(parent: shell), popup = Window(parent: page), stranger = Window()
        #expect(WindowEvents.family(of: shell, holds: shell, owner: { $0.parent }))
        #expect(WindowEvents.family(of: shell, holds: popup, owner: { $0.parent }))
        #expect(!WindowEvents.family(of: shell, holds: stranger, owner: { $0.parent }))
        #expect(!WindowEvents.family(of: shell, holds: nil, owner: { $0.parent }))
        #expect(!WindowEvents.family(of: page, holds: shell, owner: { $0.parent }))
    }
}
