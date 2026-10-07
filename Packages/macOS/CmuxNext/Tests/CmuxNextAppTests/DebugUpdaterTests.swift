import Testing
@testable import CmuxNextApp
import CmuxNextControl
import CmuxNextSettings

/// R138 update-relaunch-no-prompt: an update relaunch quits with "keep
/// sessions" and never asks.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2))) struct DebugUpdaterTests {
    @Test func relaunchRecordsKeepSessionsAndTerminatesOnce() async throws {
        let harness = try await ViewChangePermissionTests.harness()
        defer { harness.stop() }
        var terminations = 0
        let result = try DebugUpdater.run(["action": "relaunch"], harness.services, terminate: { terminations += 1 })
        #expect(result == .object(["relaunching": true]))
        #expect(terminations == 1)
        let origin = harness.services.quit.origins.consume()
        #expect(origin == .explicit(.keep))
        #expect(QuitPolicy.decide(origin, behavior: .ask, facts: .none) == .quit(.keep))
    }

    @Test func anUnknownActionIsRefused() async throws {
        let harness = try await ViewChangePermissionTests.harness()
        defer { harness.stop() }
        #expect(throws: ControlError.self) { try DebugUpdater.run(["action": "explode"], harness.services, terminate: {}) }
    }
}
