import Foundation
import Testing
@testable import CmuxMobileNotifications

/// TestFlight 1.2.0 (20261026194905) was killed by the launch watchdog
/// (0x8BADF00D, scene-create): a view body asked
/// `containerURL(forSecurityApplicationGroupIdentifier:)` on the main thread
/// for an App Group the CI App Store profile does not grant, and that
/// synchronous XPC to containermanagerd did not answer in time.
@Suite struct PushAppGroupLaunchTests {
    static let group = "group.dev.cmux.app.internal"

    /// Every container lookup the resolver makes.
    final class Lookups: @unchecked Sendable { // crash-allow: lock-guarded test recorder
        private let lock = NSLock()
        private var calls = 0
        private var onMain = 0

        func record() {
            let main = Thread.isMainThread
            lock.withLock {
                calls += 1
                if main { onMain += 1 }
            }
        }

        var count: Int { lock.withLock { calls } }
        var countOnMain: Int { lock.withLock { onMain } }
    }

    static func environment(entitled: [String]?, lookups: Lookups,
                            answer: (@Sendable () -> Void)? = nil) -> PushAppGroupResolver.Environment {
        PushAppGroupResolver.Environment(
            configuredIdentifier: { group },
            entitledGroups: { entitled },
            containerURL: { id in
                lookups.record()
                answer?()
                return FileManager.default.temporaryDirectory.appendingPathComponent(id, isDirectory: true)
            }
        )
    }

    /// The CI profile's case: signed without the group, so it is never looked up.
    @MainActor @Test func aBuildSignedWithoutTheGroupNeverLooksItUp() async {
        let lookups = Lookups()
        let resolver = PushAppGroupResolver(environment: Self.environment(entitled: [], lookups: lookups))
        resolver.start()
        #expect(await resolver.resolved() == nil)
        #expect(lookups.count == 0)
    }

    /// Launch asks from the main thread; the lookup itself never runs there, and runs once.
    @MainActor @Test func theLookupNeverRunsOnTheMainThread() async {
        let lookups = Lookups()
        let resolver = PushAppGroupResolver(environment: Self.environment(entitled: [Self.group], lookups: lookups))
        resolver.start()
        let group = await resolver.resolved()
        #expect(group?.identifier == Self.group)
        _ = await resolver.resolved()
        #expect(lookups.count == 1)
        #expect(lookups.countOnMain == 0)
    }

    /// Entitlements that cannot be read and a lookup that does not answer:
    /// starting returns at once and a reader gets "no group" after its timeout.
    @MainActor @Test func aLookupThatDoesNotAnswerNeverHoldsTheMainThread() async {
        let lookups = Lookups()
        let gate = DispatchSemaphore(value: 0)
        let resolver = PushAppGroupResolver(environment: Self.environment(entitled: nil, lookups: lookups) {
            _ = gate.wait(timeout: .now() + 3)
        })
        let clock = ContinuousClock()
        let start = clock.now
        resolver.start()
        #expect(clock.now - start < .milliseconds(250))
        #expect(await resolver.resolved(timeout: .milliseconds(200)) == nil)
        #expect(clock.now - start < .seconds(2))
        gate.signal()
    }
}
