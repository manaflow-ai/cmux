import Foundation
import Testing
@testable import CmuxControlSocket

#if DEBUG
@MainActor
private final class FakeDebugCommandPaletteContext: ControlCommandContext {
    var postedEventDescription: String?
    var postedWindowID: UUID?

    func controlDebugPostCommandPaletteEvent(
        _ event: ControlDebugCommandPaletteEvent,
        windowID: UUID?
    ) -> Bool {
        postedEventDescription = String(describing: event)
        postedWindowID = windowID
        return true
    }
}

@MainActor
@Suite("ControlCommandCoordinator command palette debug controls")
struct ControlCommandCoordinatorDebugCommandPaletteTests {
    @Test("submit posts the production palette submission event")
    func submit() {
        let context = FakeDebugCommandPaletteContext()
        let coordinator = ControlCommandCoordinator(context: context)
        let windowID = UUID()

        let result = coordinator.handle(ControlRequest(
            id: .int(1),
            method: "debug.command_palette.submit",
            params: ["window_id": .string(windowID.uuidString)]
        ))

        #expect(result == .ok(.object([:])))
        #expect(context.postedEventDescription == "submit")
        #expect(context.postedWindowID == windowID)
    }

    @Test("move posts the production palette selection delta")
    func move() {
        let context = FakeDebugCommandPaletteContext()
        let coordinator = ControlCommandCoordinator(context: context)
        let windowID = UUID()

        let result = coordinator.handle(ControlRequest(
            id: .int(1),
            method: "debug.command_palette.move",
            params: [
                "window_id": .string(windowID.uuidString),
                "delta": .int(37),
            ]
        ))

        #expect(result == .ok(.object([:])))
        #expect(context.postedEventDescription == "moveSelection(delta: 37)")
        #expect(context.postedWindowID == windowID)
    }
}
#endif
