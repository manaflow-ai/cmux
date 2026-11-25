import CmuxNextTestSupport
import Foundation
@testable import CmuxNextUpdater
import Testing

/// Go back's swap writes the same kept folder as the keep an update's staging started, on the files
/// lane at another priority, so both could run at once and the late keep could delete the copy of the
/// build this Mac came from (cmux#41013 review). The swap waits for that keep first, and refuses past
/// its limit.
@MainActor @Suite(.serialized) struct RollbackKeepRaceTests {
    private static func updater() -> UpdaterService {
        let identity = UpdateBuildIdentity(bundleIdentifier: "com.cmuxterm.app.debug.keep-race", shortVersion: "1.0.0",
                                           build: "100", minimumSystemVersion: nil,
                                           infoFeedURL: "https://files-next.cmux.com/nightly-next/appcast-arm64.xml", hasPublicKey: false)
        return UpdaterService(identity: identity, policy: ManagedUpdatePolicy { false },
                              defaults: UserDefaults(testSuiteName: "RollbackKeepRaceTests.\(UUID().uuidString)")!,
                              enableSparkle: false, recordsUpdates: false)
    }

    @Test func noKeepRunningLetsTheSwapGoAtOnce() async {
        let updater = Self.updater()
        #expect(await updater.awaitRunningKeep(limit: .milliseconds(1)))
    }

    @Test func theSwapWaitsForAKeepInFlightToEnd() async {
        let updater = Self.updater()
        updater.keptRunningBuild = .running
        updater.keepTask = Task { @MainActor [weak updater] in
            try? await Task.sleep(for: .milliseconds(50))
            updater?.keptRunningBuild = .kept
        }
        #expect(await updater.awaitRunningKeep(limit: .seconds(10)))
        #expect(updater.keptRunningBuild == .kept)
    }

    @Test func aKeepPastTheLimitRefusesTheSwap() async {
        let updater = Self.updater()
        updater.keptRunningBuild = .running
        let gate = AsyncStream<Void>.makeStream()
        updater.keepTask = Task { for await _ in gate.stream {} }
        #expect(await updater.awaitRunningKeep(limit: .milliseconds(50)) == false)
        gate.continuation.finish()
    }
}
