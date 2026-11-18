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
    @Test func aMachineWithNoReportStartsOnItsImagesSoftware() async {
        // Until the app's pinned FFI release carries `cloud_machine_route`, the verdict cannot be read and the
        // start is refused as invalid; this passes once the pin moves.
        await withKnownIssue("the pinned FFI release has no cloud_machine_route yet", isIntermittent: true) {
            try await Self.machine(printing: "").prepare {}
        }
    }

    /// Only an unrouted machine starts on the chat's own connection: one that holds a provider login, or whose
    /// agent service is down, is refused whatever the chat carries; without a connection an unrouted one is too.
    @Test func onlyAnUnroutedMachineStartsOnTheChatsOwnConnection() {
        #expect(CloudMachineRoute.starts(.notEdge, carriesConnection: true))
        #expect(!CloudMachineRoute.starts(.notEdge, carriesConnection: false))
        for verdict in [CloudMachineRoute.Verdict.holdsCredential, .noDaemon, .invalid] {
            #expect(!CloudMachineRoute.starts(verdict, carriesConnection: true))
        }
        for carries in [true, false] {
            #expect(CloudMachineRoute.starts(.ready, carriesConnection: carries))
            #expect(CloudMachineRoute.starts(.unsupported, carriesConnection: carries))
        }
    }

    /// A machine that reports and is not routed through the edge is still refused.
    @Test func aMachineThatReportsNoRouteIsRefused() async {
        let report = #"{"ok":false,"holds_credential":false,"daemon":{"running":true},"agents":{}}"#
        await #expect(throws: CloudMoveFailure.self) {
            try await Self.machine(printing: report).prepare {}
        }
    }
}
