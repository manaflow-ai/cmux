import CmuxNextCloud
import CmuxNextCloudUI
import Foundation
import Testing

/// A Cloud start's machine route check (``CloudMachineRoute/prepare(_:)``).
@Suite struct CloudMachineRouteTests {
    private static func machine(printing stdout: String) -> CloudMachineRoute {
        CloudMachineRoute(exec: { _, _ in CloudExecResult(exitCode: 0, stdout: stdout, stderr: "") })
    }

    /// DEV 36050-cloud-multiplayer: a new machine whose image software has no model-route report (it prints
    /// nothing) and that the app's update does not change refused every Cloud start.
    @Test func aMachineWithNoReportStartsOnItsImagesSoftware() async throws {
        try await Self.machine(printing: "").prepare {}
    }

    /// A machine that reports and is not routed through the edge is still refused.
    @Test func aMachineThatReportsNoRouteIsRefused() async {
        let report = #"{"ok":false,"holds_credential":false,"daemon":{"running":true},"agents":{}}"#
        await #expect(throws: CloudMoveFailure.self) {
            try await Self.machine(printing: report).prepare {}
        }
    }
}
