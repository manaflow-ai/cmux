@testable import CmuxNextApp
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextSettings
import CmuxNextWakeups
import Foundation
import Testing

/// The page relay channel off the main actor (p05-ipc-109), on the production ``DaemonPageRelay``
/// and ``PageRelayChannel`` over the fake daemon socket of ``PageRelayChannelFreezeTests``: a page
/// call runs no main-actor job between its caller's turn and its request on the socket, an event
/// reaches the page member for member with no JSON text in between, and a flood of events costs
/// the main thread at most one post per display frame for the page.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1))) struct PageRelayChannelTests {
    typealias Rig = PageRelayChannelFreezeTests.Rig

    /// The main actor is held from the call's first turn on, and the request still reaches the
    /// daemon: the call took no main-actor job before its send. (The main-actor channel waited for
    /// main after its first await, so its request came only once the main actor was free.)
    @Test func aCallReachesTheDaemonWhileTheMainActorIsHeld() async throws {
        let rig = try Rig()
        defer { rig.stop() }
        let page = rig.page()
        try await PageRelayChannelFreezeTests.historyList(page)
        let before = rig.socket.calls
        // main-hop-allow: the call's first turn must run on the main actor before the test holds it
        let call = Task { try await PageRelayChannelFreezeTests.historyList(page) }
        // The main actor runs the call's turn (queued first) before this test's next one.
        await Task.yield()
        let reached = Self.holdMainActor(seconds: 5) { rig.socket.calls > before }
        #expect(reached, "the page call's request went out while the main actor was held")
        try await call.value
    }

    /// The page gets the daemon's members as they were, without the `event` member that named it.
    @Test func anEventReachesThePageMemberForMember() async throws {
        let rig = try Rig()
        defer { rig.stop() }
        let page = rig.page()
        try await PageRelayChannelFreezeTests.subscribe(page, "cmux.history.changed", id: 1)
        rig.socket.publish(event: ["event": "history-changed", "workspace_id": "w1", "count": 3,
                                   "flags": [true, NSNull()], "nested": ["ratio": 1.5]])
        await rig.wake.frame()
        await page.sent.waitForEvents(1)
        let expected: CmuxNextSettings.JSONValue = .object([
            "workspace_id": .string("w1"), "count": .number(3), "flags": .array([.bool(true), .null]),
            "nested": .object(["ratio": .number(1.5)]),
        ])
        #expect(page.sent.events.first?["data"] == expected)
    }

    /// The conversion itself: every JSON kind moves across as it is, and only `event` is dropped.
    @Test func pageEventKeepsEveryMemberButTheEventName() {
        let daemon: CmuxNextDaemon.JSONValue = .object([
            "event": .string("history-changed"), "n": .number(-2.25), "on": .bool(false), "none": .null,
            "list": .array([.string("a"), .object(["event": .string("kept below the top")])]),
        ])
        let expected: CmuxNextSettings.JSONValue = .object([
            "n": .number(-2.25), "on": .bool(false), "none": .null,
            "list": .array([.string("a"), .object(["event": .string("kept below the top")])]),
        ])
        #expect(PageRelayChannel.pageEvent(daemon) == expected)
        #expect(PageRelayChannel.pageEvent(.array([.number(1)])) == .array([.number(1)]))
    }

    /// 1,000 events in a row: each frame runs one flush for the page (one main post), and the page
    /// gets them all or, past a frame's worth, one resync that makes it re-read.
    @Test func aFloodOfEventsTakesAtMostOnePostPerFrame() async throws {
        let rig = try Rig()
        defer { rig.stop() }
        let page = rig.page()
        try await PageRelayChannelFreezeTests.subscribe(page, "cmux.history.changed", id: 1)
        rig.socket.publish("history-changed", count: 1_000)
        var frames = 0
        while !Self.floodEnded(page.sent.events) {
            let flushes = await rig.wake.frame()
            frames += 1
            #expect(flushes == 1, "one page asks for one flush per frame")
        }
        #expect(frames <= 1_000)
        #expect(rig.wake.requests <= frames + 1, "at most one post waits for the next frame")
    }

    /// Every event of the flood arrived, or a resync stands for the ones dropped.
    static func floodEnded(_ events: [CmuxNextSettings.JSONValue]) -> Bool {
        events.count >= 1_000 || events.contains { $0["data"]?["resync"]?.boolValue == true }
    }

    /// Keeps the main actor busy (no wait, no sleep) until `done` or `seconds` pass; whether `done` came.
    static func holdMainActor(seconds: Int, until done: () -> Bool) -> Bool {
        let end = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < end {
            if done() { return true }
        }
        return false
    }
}

/// The frames of a page relay channel's events, run by the test: each flush a channel asks for
/// waits until ``frame()``, which runs every one asked for so far, as one display frame does.
nonisolated final class ManualFrameWake: Sendable {
    nonisolated private struct State {
        var flushes: [FrameOutboxWake.Flush] = []
        var waiter: CheckedContinuation<Void, Never>?
        var requests = 0
    }

    private let state = Mutex(State())

    var wake: FrameOutboxWake {
        FrameOutboxWake { [self] flush in request(flush) }
    }

    /// Flushes asked for so far (each is one main-thread post in the app).
    var requests: Int { state.withLock { $0.requests } }

    /// Waits until a flush was asked for, then runs every one asked for so far; returns how many ran.
    @MainActor @discardableResult
    func frame() async -> Int {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let ready = state.withLock { state -> Bool in
                guard state.flushes.isEmpty else { return true }
                state.waiter = continuation
                return false
            }
            if ready { continuation.resume() }
        }
        let flushes = state.withLock { state -> [FrameOutboxWake.Flush] in
            defer { state.flushes = [] }
            return state.flushes
        }
        for flush in flushes { flush() }
        return flushes.count
    }

    private func request(_ flush: @escaping FrameOutboxWake.Flush) {
        let waiter = state.withLock { state -> CheckedContinuation<Void, Never>? in
            state.flushes.append(flush)
            state.requests += 1
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume()
    }
}
