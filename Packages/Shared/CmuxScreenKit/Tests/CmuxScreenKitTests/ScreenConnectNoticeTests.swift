import CmuxScreenKit
import Foundation
import Testing

/// Leo, 2026-11-14: "i also want all our connectivity stuff to shut up and load faster".
/// The iPhone's Screen Sharing said "Connecting to {Mac}…" from the first frame of every first
/// connect. Now a first connect says nothing for `ScreenSession.connectNoticeDelay` and a
/// reconnect for `reconnectNoticeDelay`, both the shared 10 s bound, both on the session's injected `noticeClock`.
@MainActor
struct ScreenConnectNoticeTests {
    private func session(_ clock: some Clock<Duration>) -> ScreenSession {
        let session = ScreenSession(title: "Studio", signaling: { SilentSignaling() })
        session.noticeClock = clock
        return session
    }

    @Test func aFirstConnectSaysNothingUnderTheSharedBound() async {
        let session = session(ParkedClock())
        defer { session.close() }
        session.connect()
        #expect(session.phase == .connecting && !session.isReconnecting)
        for _ in 0 ..< 50 { await Task.yield() }
        #expect(!session.connectingNoticeShown, "a connect under its notice bound draws no card")
        #expect(ScreenSession.connectNoticeDelay == .seconds(10), "one bound: schemas/notice-timing connectionQuietMs")
    }

    @Test func aFirstConnectThatLastsIsSaid() async {
        let session = session(SoonClock())
        defer { session.close() }
        session.connect()
        for _ in 0 ..< 200 where !session.connectingNoticeShown { await Task.yield() }
        #expect(session.phase == .connecting)
        #expect(session.connectNoticeDue)
        #expect(session.connectingNoticeShown, "past the bound the card says it connects")
    }

    @Test func aReconnectWaitsItsOwnLongerBound() async {
        let session = session(ParkedClock())
        defer { session.close() }
        session.prepareForReconnect()
        #expect(session.isReconnecting && session.phase == .connecting)
        for _ in 0 ..< 50 { await Task.yield() }
        #expect(!session.connectingNoticeShown, "a reconnect under 10 s keeps the last frame and says nothing")
    }
}

/// Signaling that never answers: the session stays connecting while the test runs.
private final class SilentSignaling: ScreenSignaling, @unchecked Sendable {
    func messages() -> AsyncThrowingStream<ScreenSignal, any Error> { AsyncThrowingStream { _ in } }
    func send(_: ScreenSignal) async throws {}
    func iceServers() async throws -> [ICEServerConfig] { [] }
    func close() {}
    var endsSessionOnClose: Bool { true }
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

/// A clock whose sleeps end on the next task turn.
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
