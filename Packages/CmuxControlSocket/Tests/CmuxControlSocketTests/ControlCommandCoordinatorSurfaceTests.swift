import Foundation
import Testing
@testable import CmuxControlSocket

@MainActor
@Suite("ControlCommandCoordinator surface domain")
struct ControlCommandCoordinatorSurfaceTests {
    private func coordinator(
        createResolution: ControlSurfaceCreateResolution
    ) -> (ControlCommandCoordinator, FakeSurfaceControlCommandContext) {
        let context = FakeSurfaceControlCommandContext()
        context.createResolution = createResolution
        return (ControlCommandCoordinator(context: context), context)
    }

    @Test func surfaceCreateDockUnsupportedTypeReturnsInvalidParams() throws {
        let (coordinator, context) = coordinator(createResolution: .dockUnsupportedType(
            typeRawValue: "agentSession",
            message: "Dock placement supports only terminal and browser surfaces"
        ))
        let result = coordinator.handle(ControlRequest(
            id: .int(1),
            method: "surface.create",
            params: [
                "type": .string("agent-session"),
                "placement": .string("dock"),
            ]
        ))
        _ = context

        guard case .err(let code, let message, let data) = result else {
            Issue.record("expected invalid_params error")
            return
        }

        #expect(code == "invalid_params")
        #expect(message == "Dock placement supports only terminal and browser surfaces")
        #expect(data == .object(["type": .string("agentSession")]))
    }
}
