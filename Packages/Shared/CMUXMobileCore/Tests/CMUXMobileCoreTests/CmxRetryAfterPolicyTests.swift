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
        let runChunkedSleep = CmxRetryAfterPolicy.sleep
        do {
            try await runChunkedSleep(seconds: 18_446_744_074) { chunk in
                #expect(chunk == 86_400)
                throw CancellationError()
            }
            Issue.record("Expected cancellation to stop the long sleep")
        } catch is CancellationError {}
        let time = RetryAfterTestTime()
        try await runChunkedSleep(seconds: 172_801) { chunk in
            #expect(chunk > 0 && chunk <= 86_400)
            time.advance(by: chunk)
        }
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
