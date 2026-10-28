@testable import CmuxNextDevices
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Foundation
import Testing

/// The hub socket pings nothing while the Mac sleeps, keeps pinging while only the
/// displays sleep, and a wake that finds the network reconnects it exactly once, within the wake's
/// jitter instead of its backoff.
@Suite(.timeLimit(.minutes(1)))
struct DeviceHubSocketWakeTests {
    /// A socket that stays open until it is closed, recording what it sent; ``sends`` yields each sent frame.
    // crash-allow: test fake; `sentFrames` and `closed` are read and written only under `lock`.
    final class HeldConnection: DeviceHubSocketConnection, @unchecked Sendable {
        private let lock = NSLock()
        private var sentFrames: [String] = []
        private var isClosed = false
        private let frames: AsyncStream<String>
        private let feed: AsyncStream<String>.Continuation
        let sends: AsyncStream<String>
        private let sending: AsyncStream<String>.Continuation

        init() {
            (frames, feed) = AsyncStream.makeStream(of: String.self)
            (sends, sending) = AsyncStream.makeStream(of: String.self)
        }

        var sent: [String] { lock.withLock { sentFrames } }
        var closed: Bool { lock.withLock { isClosed } }

        func receive() async throws -> String {
            for await frame in frames { return frame }
            throw URLError(.networkConnectionLost)
        }

        func send(_ text: String) async throws {
            lock.withLock { sentFrames.append(text) }
            sending.yield(text)
        }

        func close() {
            lock.withLock { isClosed = true }
            feed.finish()
        }
    }

    /// Hands out `connections` in order, counting the attempts.
    // crash-allow: test fake; `queue` and `count` are read and written only under `lock`.
    final class Connections: DeviceHubSocketConnector, @unchecked Sendable {
        private let lock = NSLock()
        private var queue: [HeldConnection]
        private var count = 0

        init(_ connections: [HeldConnection]) { queue = connections }

        var attempts: Int { lock.withLock { count } }

        func connect() async throws -> any DeviceHubSocketConnection {
            let next = lock.withLock { () -> HeldConnection? in
                count += 1
                return queue.isEmpty ? nil : queue.removeFirst()
            }
            guard let next else { throw URLError(.cannotConnectToHost) }
            return next
        }
    }

    /// Reads events until one `matches` it (or the stream ends). `@concurrent`, like
    /// `AsyncStream.Iterator.next()`: the caller sends its iterator here once and the reads do not hop
    /// isolation again (the target's default isolation is the main actor), as BranchSizedForTests.notice does.
    @concurrent nonisolated static func skip(_ iterator: inout AsyncStream<DeviceHubSocket.Event>.Iterator,
                                             until matches: @Sendable (DeviceHubSocket.Event) -> Bool) async {
        while let seen = await iterator.next() {
            if matches(seen) { return }
        }
    }

    @Test func sleepSendsNoPingAndAWakeReconnectsOnce() async throws {
        let first = HeldConnection(), second = HeldConnection()
        let connector = Connections([first, second])
        let clock = ManualClock()
        let energy = EnergyPolicySource()
        let socket = DeviceHubSocket(connector: connector, pingInterval: .seconds(30),
                                     backoff: Backoff(initial: .seconds(3600), maximum: .seconds(3600), jitter: 0),
                                     clock: clock, energy: energy, wakeJitter: { 0.5 })
        let (events, event) = AsyncStream.makeStream(of: DeviceHubSocket.Event.self)
        let task = Task { await socket.run { event.yield($0) } }
        var iterator = events.makeAsyncIterator()

        await Self.skip(&iterator) { $0 == .state(.connected) }
        try await clock.waitForSleeper()
        #expect(clock.sleepRequests.last?.deadline.offset == .seconds(30))

        // Asleep: the armed ping goes, and no time passing sends one.
        energy.update(EnergyPolicy(suspended: true))
        #expect(clock.sleeperCount == 0)
        clock.advance(by: .seconds(600))
        #expect(first.sent.isEmpty)

        // Awake: the ping is armed again, a whole interval from now.
        energy.update(EnergyPolicy())
        try await clock.waitForSleeper()
        #expect(clock.sleepRequests.last?.deadline.offset == .seconds(630))

        // The path is back: the socket that slept closes and the next one opens 1 s later, not an hour.
        energy.update(EnergyPolicy(networkResumes: 1))
        #expect(first.closed)
        await Self.skip(&iterator) { if case .state(.reconnecting) = $0 { true } else { false } }
        try await clock.waitForSleeper()
        #expect(clock.sleepRequests.last?.deadline.offset == .seconds(601))
        clock.advance(by: .seconds(1))
        await Self.skip(&iterator) { $0 == .state(.connected) }
        #expect(connector.attempts == 2)
        #expect(first.sent.isEmpty)

        // The same policy again reconnects nothing.
        energy.update(EnergyPolicy(networkResumes: 1, onBattery: true))
        #expect(!second.closed)
        #expect(connector.attempts == 2)
        task.cancel()
        await task.value
    }

    @Test func theDisplaysSleepingStillSendThePingAfterAnIntervalOfSilence() async throws {
        let connection = HeldConnection()
        let connector = Connections([connection])
        let clock = ManualClock()
        let energy = EnergyPolicySource()
        let socket = DeviceHubSocket(connector: connector, pingInterval: .seconds(30), clock: clock, energy: energy)
        let (events, event) = AsyncStream.makeStream(of: DeviceHubSocket.Event.self)
        let task = Task { await socket.run { event.yield($0) } }
        var iterator = events.makeAsyncIterator()

        await Self.skip(&iterator) { $0 == .state(.connected) }
        try await clock.waitForSleeper()
        #expect(clock.sleepRequests.last?.deadline.offset == .seconds(30))

        // Only the displays sleep: the Mac is still the Mac Screen host a phone reaches, so the armed
        // ping stays, goes out after the interval, and the next one is armed behind it.
        energy.update(EnergyPolicy(screensAsleep: true))
        #expect(clock.sleeperCount == 1)
        clock.advance(by: .seconds(30))
        for await _ in connection.sends { break }
        #expect(connection.sent == [#"{"type":"ping"}"#])
        try await clock.waitForSleeper()
        #expect(clock.sleepRequests.last?.deadline.offset == .seconds(60))
        #expect(!connection.closed)
        #expect(connector.attempts == 1)
        task.cancel()
        await task.value
    }

    @Test func aWakeDuringTheBackoffEndsItEarly() async throws {
        let connector = Connections([])
        let clock = ManualClock()
        let energy = EnergyPolicySource()
        let socket = DeviceHubSocket(connector: connector, backoff: Backoff(initial: .seconds(3600), maximum: .seconds(3600), jitter: 0),
                                     clock: clock, energy: energy, wakeJitter: { 0 })
        let (events, event) = AsyncStream.makeStream(of: DeviceHubSocket.Event.self)
        let task = Task { await socket.run { event.yield($0) } }
        for await seen in events {
            if case .state(.reconnecting) = seen { break }
        }
        try await clock.waitForSleeper()
        #expect(clock.sleepRequests.last?.deadline.offset == .seconds(3600))
        energy.update(EnergyPolicy(networkResumes: 1))
        // The hour's wait ends; the next attempt follows at once (jitter 0) and fails again here.
        for await seen in events {
            if case .state(.reconnecting) = seen { break }
        }
        #expect(connector.attempts == 2)
        task.cancel()
        await task.value
    }
}
