import AppKit
@testable import CmuxNextApp
import CmuxNextWakeups
import Testing

/// Leo, 2026-11-14: "i also want all our connectivity stuff to shut the fuck up and load
/// faster/percievably load faster / whatever it takes / desktop gui, ios, remote, cloud, etc".
/// A remote terminal tab whose session is reattaching said "Reconnecting to {machine}…" from its first
/// frame, on every launch and every drop, though its daemon redials on its own. Now it shows the saved
/// screen alone for `reconnectQuiet` (10 s) and says the reconnect only once it lasts; "offline" with
/// Connect, which a person can act on, shows at once.
@MainActor
@Suite struct RemoteTerminalReconnectQuietTests {
    static func placeholder(_ clock: some Clock<Duration>) -> RemoteTerminalPlaceholderView {
        let view = RemoteTerminalPlaceholderView(frame: .zero)
        view.reconnectHold = QuietHold(owner: "test", delay: .seconds(10), clock: clock)
        return view
    }

    @Test func aReconnectShowsTheSavedScreenAloneUntilItLasts() async {
        let view = Self.placeholder(ParkedClock())
        view.show(machine: "studio", state: .reconnecting, snapshot: "$ make test")
        #expect(view.reconnectHold.held, "a reconnect under 10 s says nothing")
        #expect(view.snapshotText == "$ make test", "the saved screen draws at once")
        // Shown again while the same reconnect goes on: still held, never restarted or flashed.
        view.show(machine: "studio", state: .reconnecting, snapshot: "$ make test")
        #expect(view.reconnectHold.held)
    }

    @Test func aReconnectThatLastsIsSaidOnce() async {
        let view = Self.placeholder(SoonClock())
        view.show(machine: "studio", state: .reconnecting, snapshot: nil)
        for _ in 0..<200 where view.reconnectHold.held { await Task.yield() }
        #expect(!view.reconnectHold.held, "past the bound the line shows")
        #expect(view.statusText == RemoteStrings.placeholderReconnecting("studio"))
        view.show(machine: "studio", state: .reconnecting, snapshot: nil)
        #expect(!view.reconnectHold.held, "once said, the same reconnect is not hidden again")
    }

    @Test func offlineWithConnectShowsAtOnce() {
        let view = Self.placeholder(ParkedClock())
        view.show(machine: "studio", state: .reconnecting, snapshot: nil)
        view.onConnect = {}
        view.show(machine: "studio", state: .offline, snapshot: nil)
        #expect(!view.reconnectHold.held)
        #expect(view.statusText == RemoteStrings.placeholderOffline("studio"))
    }
}

/// A clock whose sleeps never end while the test runs.
private struct ParkedClock: Clock {
    struct Instant: InstantProtocol {
        var offset: Duration = .zero

        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    var now: Instant { Instant() }
    var minimumResolution: Duration { .nanoseconds(1) }

    func sleep(until _: Instant, tolerance _: Duration?) async throws {
        try await Task.sleep(for: .seconds(3_600))
    }
}

/// A clock whose sleeps complete on the next task turn.
private struct SoonClock: Clock {
    struct Instant: InstantProtocol {
        var offset: Duration = .zero

        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    var now: Instant { Instant() }
    var minimumResolution: Duration { .nanoseconds(1) }

    func sleep(until _: Instant, tolerance _: Duration?) async throws {}
}
