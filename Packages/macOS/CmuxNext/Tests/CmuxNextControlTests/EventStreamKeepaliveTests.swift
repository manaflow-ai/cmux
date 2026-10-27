@testable import CmuxNextControl
import CmuxNextSettings
import CmuxNextWakeupsTestSupport
import Foundation
import Testing

/// `events.stream`'s heartbeat is a keepalive: it goes out only after `heartbeat_interval_seconds` of silence,
/// and every line the stream writes moves it on (a `DemandTimer` re-armed per line, never a periodic loop).
/// Before, a loop slept 15 s and wrote a heartbeat whatever the stream had just written, so each client woke
/// the process every 15 s even while events flowed.
struct EventStreamKeepaliveTests {
    @Test(.timeLimit(.minutes(1)))
    func anEventPushesTheHeartbeatBackAWholePeriod() async throws {
        let clock = ManualClock()
        let router = ControlRouter(identity: testIdentity(), executor: RecordingExecutor(), configuration: .loadTolerant)
        let (lines, line) = AsyncStream<String>.makeStream()
        let (hangups, hangup) = AsyncStream<Void>.makeStream()
        let stream = Task {
            await router.streamEvents(ControlRequest(id: "1", method: ControlRouter.eventStreamMethod, params: [:]),
                                      emit: { line.yield($0) }, hangup: { for await _ in hangups {} }, clock: clock)
        }
        var written = lines.makeAsyncIterator()
        let ackLine = await written.next()
        let ack = try JSONValue.parse(Data(#require(ackLine).utf8))
        #expect(ack["type"] == "ack")
        try await clock.waitForSleeper()
        #expect(clock.sleepRequests.last?.deadline == ManualClock.Instant(offset: .seconds(15)), "15 s of silence after the ack")

        clock.advance(by: .seconds(10))
        router.events.publish(name: "keepalive.test", category: "test", source: "test", payload: [:])
        let eventLine = await written.next()
        let event = try JSONValue.parse(Data(#require(eventLine).utf8))
        #expect(event["type"] == "event")
        try await clock.waitForSleeper()
        #expect(clock.sleepRequests.last?.deadline == ManualClock.Instant(offset: .seconds(25)),
                "the event at 10 s moves the heartbeat to 25 s: \(String(describing: clock.sleepRequests.last))")

        clock.advance(by: .seconds(15))
        let heartbeatLine = await written.next()
        let heartbeat = try JSONValue.parse(Data(#require(heartbeatLine).utf8))
        #expect(heartbeat["type"] == "heartbeat")
        try await clock.waitForSleeper()
        #expect(clock.sleepRequests.last?.deadline == ManualClock.Instant(offset: .seconds(40)), "the heartbeat re-arms the next one")

        hangup.finish()
        await stream.value
        line.finish()
    }
}
