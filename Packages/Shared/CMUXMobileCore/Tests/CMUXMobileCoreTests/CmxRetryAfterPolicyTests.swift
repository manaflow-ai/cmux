import Foundation
import Testing

@testable import CMUXMobileCore

@Suite struct CmxRetryAfterPolicyTests {
    @Test func parsesDeltaSecondsAndHTTPDate() throws {
        #expect(CmxRetryAfterPolicy.seconds(from: "45") == 45)
        #expect(CmxRetryAfterPolicy.seconds(from: "0") == nil)
        #expect(CmxRetryAfterPolicy.seconds(from: "invalid") == nil)

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss 'GMT'"
        let header = formatter.string(from: now.addingTimeInterval(45))
        #expect(CmxRetryAfterPolicy.seconds(from: header, now: now) == 45)
    }

    @Test func serverDirectiveFloorsLocalBackoff() {
        #expect(CmxRetryAfterPolicy.delay(localSeconds: 2, retryAfterSeconds: 45) == 45)
        #expect(CmxRetryAfterPolicy.delay(localSeconds: 60, retryAfterSeconds: 45) == 60)
        #expect(CmxRetryAfterPolicy.delay(localSeconds: 2, retryAfterSeconds: nil) == 2)
    }

    @Test func cooldownExtendsAndNeverShortens() async {
        let time = RetryAfterTestTime()
        let gate = CmxRetryAfterGate(
            now: { time.now },
            sleep: { delay in time.advance(by: delay) }
        )

        await gate.extend(by: 45)
        await gate.extend(by: 10)
        #expect(await gate.remainingSeconds() == 45)
        try? await gate.wait()
        #expect(time.now == 45)
        #expect(await gate.remainingSeconds() == nil)
    }

    @Test func oversizedCooldownDoesNotOverflowOrLoseTheDeadline() async {
        let gate = CmxRetryAfterGate(now: { 0 }, sleep: { _ in })
        await gate.extend(by: Int.max)
        #expect(await gate.remainingSeconds() == Int.max)
    }

    @Test func sendsWaitForThePreviousResponseAndItsCooldown() async throws {
        let time = RetryAfterTestTime()
        let gate = CmxRetryAfterGate(now: { time.now }, sleep: { time.advance(by: $0) })
        let started = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let first = Task {
            try await gate.perform {
                started.continuation.yield(())
                for await _ in release.stream { break }
                await gate.extend(by: 45)
                return 1
            }
        }
        for await _ in started.stream { break }
        let second = Task { try await gate.perform { time.now } }
        release.continuation.yield(())
        #expect(try await first.value == 1)
        #expect(try await second.value == 45)
    }

    @Test func oversizedSleepUsesSafeChunksWithoutShorteningTheWait() async throws {
        let firstChunks = AsyncStream<TimeInterval>.makeStream()
        do {
            try await CmxRetryAfterPolicy.sleep(seconds: 18_446_744_074) { chunk in
                firstChunks.continuation.yield(chunk)
                throw CancellationError()
            }
            Issue.record("Expected cancellation to stop the long sleep")
        } catch is CancellationError {}
        firstChunks.continuation.finish()
        let cancelledChunks = await firstChunks.stream.reduce(into: [TimeInterval]()) { $0.append($1) }
        #expect(cancelledChunks == [86_400])

        let secondChunks = AsyncStream<TimeInterval>.makeStream()
        let time = RetryAfterTestTime()
        try await CmxRetryAfterPolicy.sleep(seconds: 172_801) { chunk in
            secondChunks.continuation.yield(chunk)
            time.advance(by: chunk)
        }
        secondChunks.continuation.finish()
        let completedChunks = await secondChunks.stream.reduce(into: [TimeInterval]()) { $0.append($1) }
        #expect(completedChunks == [86_400, 86_400, 1])
        #expect(time.now == 172_801)
    }
}

private final class RetryAfterTestTime: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 0

    var now: TimeInterval {
        lock.withLock { value }
    }

    func advance(by delay: TimeInterval) {
        lock.withLock { value += delay }
    }
}
