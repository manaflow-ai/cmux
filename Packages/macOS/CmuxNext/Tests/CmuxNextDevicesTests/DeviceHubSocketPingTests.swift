@testable import CmuxNextDevices
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Foundation
import Testing

/// The hub socket's keepalive goes only after a whole interval of silence, at most a
/// tenth of the interval late. A socket with a frame every 5 s and a 15 s interval sends no ping at all.
@Suite(.timeLimit(.minutes(1)))
struct DeviceHubSocketPingTests {
    /// An open socket the test feeds frames into; ``sends`` yields each frame it sent.
    // crash-allow: test fake; `sentFrames` is read and written only under `lock`.
    final class FedConnection: DeviceHubSocketConnection, @unchecked Sendable {
        private let lock = NSLock()
        private var sentFrames: [String] = []
        private let frames: AsyncStream<String>
        private let feed: AsyncStream<String>.Continuation
        let sends: AsyncStream<String>
        private let sending: AsyncStream<String>.Continuation

        init() {
            (frames, feed) = AsyncStream.makeStream(of: String.self)
            (sends, sending) = AsyncStream.makeStream(of: String.self)
        }

        var sent: [String] { lock.withLock { sentFrames } }

        /// The server sends `frame`.
        func push(_ frame: String) { feed.yield(frame) }

        func receive() async throws -> String {
            for await frame in frames { return frame }
            throw URLError(.networkConnectionLost)
        }

        func send(_ text: String) async throws {
            lock.withLock { sentFrames.append(text) }
            sending.yield(text)
        }

        func close() { feed.finish() }
    }

    struct One: DeviceHubSocketConnector {
        let connection: FedConnection
        func connect() async throws -> any DeviceHubSocketConnection { connection }
    }

    @Test func trafficEveryFiveSecondsSendsNoPing() async throws {
        let connection = FedConnection()
        let clock = ManualClock()
        let socket = DeviceHubSocket(connector: One(connection: connection), pingInterval: .seconds(15), clock: clock)
        let (events, event) = AsyncStream.makeStream(of: DeviceHubSocket.Event.self)
        let task = Task { await socket.run { event.yield($0) } }
        var iterator = events.makeAsyncIterator()

        await DeviceHubSocketWakeTests.skip(&iterator) { $0 == .state(.connected) }
        try await clock.waitForSleeper()
        #expect(clock.sleepRequests.last?.deadline.offset == .seconds(15))
        #expect(clock.sleepRequests.last?.tolerance == .milliseconds(1500), "the ping's leeway is not a tenth of its interval")

        // A frame every 5 s for a minute: each one pushes the ping a whole interval out, so none is ever due.
        for second in stride(from: 5, through: 60, by: 5) {
            clock.advance(by: .seconds(5))
            connection.push(#"{"type":"devices.changed"}"#)
            await DeviceHubSocketWakeTests.skip(&iterator) { $0 == .push(.devicesChanged) }
            try await clock.waitForSleeper()
            #expect(clock.sleepRequests.last?.deadline.offset == .seconds(second + 15))
        }
        #expect(connection.sent.isEmpty, "a socket with traffic sent a ping")

        // The traffic stops: one ping a whole interval after the last frame, and the next one an interval later.
        clock.advance(by: .seconds(15))
        for await _ in connection.sends { break }
        #expect(connection.sent == [#"{"type":"ping"}"#])
        try await clock.waitForSleeper()
        #expect(clock.sleepRequests.last?.deadline.offset == .seconds(90))
        task.cancel()
        await task.value
    }
}
