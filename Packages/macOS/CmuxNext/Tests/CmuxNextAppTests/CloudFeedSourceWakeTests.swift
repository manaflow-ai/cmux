@testable import CmuxNextFeed
import CmuxNextWakeups
import Foundation
import Testing

/// A wake that finds the network closes the feed socket that slept and opens one new
/// connection at once (jitter 0 here), not after the reconnect backoff.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct CloudFeedSourceWakeTests {
    @MainActor private final class Count {
        var value = 0
    }

    @Test func aWakeReconnectsTheFeedSocketOnce() async throws {
        let energy = EnergyPolicySource()
        let count = Count()
        let (attempts, attempt) = AsyncStream.makeStream(of: Int.self)
        let source = CloudFeedSource(
            apiBaseURL: URL(string: "https://api.test")!, device: "Mac", mainWork: linklessMainWork(), token: { "t" },
            reconnect: Backoff(initial: .seconds(3600), maximum: .seconds(3600), jitter: 0),
            connect: { _, onSnapshot, opened in
                count.value += 1
                let (held, hold) = AsyncStream.makeStream(of: Void.self)
                opened { hold.finish() }
                onSnapshot()
                attempt.yield(count.value)
                for await _ in held {}
                throw URLError(.networkConnectionLost)
            },
            energy: energy, wakeJitter: { 0 })
        source.start { _ in }
        for await number in attempts {
            guard number == 1 else { break }
            energy.update(EnergyPolicy(suspended: true))
            energy.update(EnergyPolicy())
            energy.update(EnergyPolicy(networkResumes: 1))
        }
        #expect(count.value == 2)
        // The same policy again closes nothing.
        energy.update(EnergyPolicy(networkResumes: 1, onBattery: true))
        source.stop()
        #expect(count.value == 2)
    }
}
