import CmuxNextCloud
import CmuxNextCloudUI
import Foundation
import Testing

/// A Cloud start's machine route check (``CloudMachineRoute/prepare(hasMachineBuild:_:)``) on a machine whose
/// software predates the model-route report (it prints nothing for the report's command).
@Suite struct CloudMachineRouteTests {
    /// A machine that prints nothing for any command: its cmux-tui has no `machine-auth`.
    private static let silent = CloudMachineRoute(exec: { _, _ in CloudExecResult(exitCode: 0, stdout: "", stderr: "") })

    /// DEV 36050-cloud-multiplayer: an app with no machine build of its own (a DEV build of an unpublished
    /// commit) refused every Cloud start, since no update could ever give the machine the report.
    @Test func anAppWithNoMachineBuildStartsOnTheImagesSoftware() async throws {
        try await Self.silent.prepare(hasMachineBuild: { false }) {}
    }

    /// An app that has a machine build still refuses a machine its update did not reach.
    @Test func anAppWithAMachineBuildRefusesAMachineItsUpdateDidNotReach() async {
        await #expect(throws: CloudMoveFailure.self) {
            try await Self.silent.prepare(hasMachineBuild: { true }) {}
        }
    }
}
