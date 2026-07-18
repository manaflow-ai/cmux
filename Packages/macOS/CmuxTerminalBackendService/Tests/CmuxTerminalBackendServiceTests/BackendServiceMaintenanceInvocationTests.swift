import CmuxTerminalBackendService
import Testing

@Suite("Persistent backend maintenance routing")
struct BackendServiceMaintenanceInvocationTests {
    @Test("status and unregister require exact argument vectors")
    func exactCommands() {
        #expect(
            BackendServiceMaintenanceInvocation(
                arguments: ["cmux", BackendServiceMaintenanceInvocation.statusArgument]
            )?.operation == .status
        )
        #expect(
            BackendServiceMaintenanceInvocation(
                arguments: ["cmux", BackendServiceMaintenanceInvocation.unregisterArgument]
            )?.operation == .unregister
        )
    }

    @Test(
        "unrelated and augmented launches never enter maintenance",
        arguments: [
            ["cmux"],
            ["cmux", "--help"],
            ["cmux", "--help", BackendServiceMaintenanceInvocation.unregisterArgument],
            ["cmux", BackendServiceMaintenanceInvocation.unregisterArgument, "--force"],
            ["cmux", BackendServiceMaintenanceInvocation.statusArgument, "workspace"],
        ]
    )
    func rejectsNonExactCommands(arguments: [String]) {
        #expect(BackendServiceMaintenanceInvocation(arguments: arguments) == nil)
    }
}
