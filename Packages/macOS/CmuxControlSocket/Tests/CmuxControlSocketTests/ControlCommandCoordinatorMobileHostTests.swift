import Testing
@testable import CmuxControlSocket

@MainActor
private final class FakeMobileHostControlCommandContext: ControlCommandContext {
    var closeCalls: [[String: JSONValue]] = []
    var closeResult: ControlCallResult = .ok(.object(["closed": .bool(true)]))

    func controlMobileTerminalClose(params: [String: JSONValue]) -> ControlCallResult {
        closeCalls.append(params)
        return closeResult
    }
}

@MainActor
@Suite("ControlCommandCoordinator mobile-host domain")
struct ControlCommandCoordinatorMobileHostTests {
    @Test(arguments: ["mobile.terminal.close", "terminal.close"])
    func terminalCloseAliasesRouteThroughMobileHostContext(method: String) {
        let context = FakeMobileHostControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)
        let result = coordinator.handle(
            ControlRequest(
                id: .int(1),
                method: method,
                params: ["surface_id": .string("surface-1")]
            )
        )

        #expect(result == .ok(.object(["closed": .bool(true)])))
        #expect(context.closeCalls.count == 1)
        #expect(context.closeCalls.first?["surface_id"] == .string("surface-1"))
    }
}
