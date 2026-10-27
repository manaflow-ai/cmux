@testable import CmuxNextApp
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextSettings
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Foundation
import Testing

/// The page relay channel off the main actor (p05-ipc-109), on the production ``DaemonPageRelay``
/// and ``PageRelayChannel`` over the fake daemon socket of ``PageRelayChannelFreezeTests``: a page
/// call runs no main-actor job between its caller's turn and its request on the socket, an event
/// reaches the page as the daemon's undecoded line (0 app JSON decodes), and a flood of events
/// costs the main thread at most one post and one flush per display frame for the page.
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

    /// The page gets the daemon's line as the daemon sent it, as JSON text the app never decodes:
    /// the relay connection's JSON decodes (its wire counter, where every app decode of its lines is
    /// counted) do not move while the event reaches the page, and the page parses the text (here,
    /// the test does) to every member, `event` included. Before, the connection decoded each line
    /// into a `JSONValue` (1 decode per event) and the channel copied it into the page's value.
    @Test func anEventReachesThePageWithNoAppDecode() async throws {
        let rig = try Rig()
        defer { rig.stop() }
        let page = rig.page()
        try await PageRelayChannelFreezeTests.subscribe(page, "cmux.history.changed", id: 1)
        let decodes = rig.stats.snapshot().jsonDecodes
        rig.socket.publish(event: ["event": "history-changed", "workspace_id": "w1", "count": 3,
                                   "flags": [true, NSNull()], "nested": ["ratio": 1.5]])
        await rig.wake.frame()
        await page.sent.waitForEvents(1)
        #expect(rig.stats.snapshot().jsonDecodes == decodes, "0 app JSON decodes per relayed event")
        let event = try #require(page.sent.events.first)
        #expect(event["data"] == nil, "the line goes as `json`, not as a value the app built")
        let text = try #require(event["json"]?.stringValue, "\(event)")
        let expected: CmuxNextSettings.JSONValue = .object([
            "event": .string("history-changed"), "workspace_id": .string("w1"), "count": .number(3),
            "flags": .array([.bool(true), .null]), "nested": .object(["ratio": .number(1.5)]),
        ])
        #expect(try CmuxNextSettings.JSONValue.parse(Data(text.utf8)) == expected)
    }

    /// 1,000 events in a row on the app's wake (``FrameOutboxWake/nextFrame(owner:on:)``, as
    /// ``DaemonPageRelay/init(services:)`` makes it) over a scheduler whose frames the test fires,
    /// counted from the board's ledger: each frame runs at most one main post
    /// (`PageRelayChannel.events`) and one flush (`PageRelayChannel.events.flush`) for the page, and
    /// the page gets every event or, past a frame's worth, one resync that makes it re-read.
    @Test func aFloodOfEventsTakesAtMostOnePostAndOneFlushPerFrame() async throws {
        let rig = try Rig()
        defer { rig.stop() }
        let frames = ManualMainFrames()
        let owner = "PageRelayChannel.events", flushOwner = owner + ".flush"
        let page = rig.page(eventWake: { FrameOutboxWake.nextFrame(owner: owner, on: frames.work) })
        try await PageRelayChannelFreezeTests.subscribe(page, "cmux.history.changed", id: 1)
        rig.socket.publish("history-changed", count: 1_000)
        var ticks = 0
        while !Self.floodEnded(page.sent.events), ticks < 2_000 {
            let posts = frames.tasks(of: owner), flushes = frames.tasks(of: flushOwner)
            // One frame interval: the main run loop's turns, where posts made off main arrive, then the frame.
            frames.runTurnsBetweenFrames()
            frames.tick()
            ticks += 1
            #expect(frames.tasks(of: owner) - posts <= 1, "at most one main post a frame for the page")
            #expect(frames.tasks(of: flushOwner) - flushes <= 1, "at most one flush a frame for the page")
        }
        #expect(Self.floodEnded(page.sent.events), "the page got the flood or a resync in \(ticks) frames")
        #expect(frames.tasks(of: flushOwner) >= 1)
        #expect(frames.tasks(of: owner) <= ticks + 1, "never more posts than frames")
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
