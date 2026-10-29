import CmuxNextDaemon
import CmuxNextDaemonService
import Testing
@testable import CmuxNextApp

/// Terminal views attach on their machine's connection: `DaemonService.machineConnection()` is
/// the seam both terminal call sites pass to `DaemonTerminalIO`, and it refuses the same way `endpoint()` did.
@MainActor
struct DaemonMachineConnectionTests {
    @Test func aServiceNotStartedHasNoConnectionAndNoEndpoint() async {
        let daemon = DaemonService(machineID: "remote")
        await #expect(throws: DaemonError.notConnected) { _ = try await daemon.machineConnection() }
        await #expect(throws: DaemonError.notConnected) { _ = try await daemon.endpoint() }
    }

    @Test func aMachineTurnedOffByItsOrganizationRefusesTheConnection() async {
        let daemon = DaemonService(machineID: "remote")
        daemon.policyBlock.set(true)
        await #expect(throws: DaemonError.endpointBlocked("turned off by your organization")) {
            _ = try await daemon.machineConnection()
        }
        await #expect(throws: DaemonError.endpointBlocked("turned off by your organization")) {
            _ = try await daemon.endpoint()
        }
    }
}
