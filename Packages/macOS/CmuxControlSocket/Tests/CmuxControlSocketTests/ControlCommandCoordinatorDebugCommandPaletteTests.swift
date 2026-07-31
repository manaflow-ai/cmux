import Foundation
import Testing
@testable import CmuxControlSocket

#if DEBUG
@MainActor
private final class FakeDebugCommandPaletteControlCommandContext: ControlCommandContext {
    var postedEvents: [(ControlDebugCommandPaletteEvent, UUID?)] = []
    var shouldPost = true

    func controlDebugPostCommandPaletteEvent(
        _ event: ControlDebugCommandPaletteEvent,
        windowID: UUID?
    ) -> Bool {
        postedEvents.append((event, windowID))
        return shouldPost
    }
}

@MainActor
@Suite("ControlCommandCoordinator debug command palette dispatch")
struct ControlCommandCoordinatorDebugCommandPaletteTests {
    private func makeCoordinator() -> (ControlCommandCoordinator, FakeDebugCommandPaletteControlCommandContext) {
        let context = FakeDebugCommandPaletteControlCommandContext()
        return (ControlCommandCoordinator(context: context), context)
    }

    private func request(
        _ method: String,
        _ params: [String: JSONValue] = [:]
    ) -> ControlRequest {
        ControlRequest(id: .int(1), method: method, params: params)
    }

    @Test func querySetPreservesTextAndTargetsExactWindow() {
        let (coordinator, context) = makeCoordinator()
        let windowID = UUID()

        let result = coordinator.handle(request(
            "debug.command_palette.query.set",
            [
                "query": .string("update"),
                "window_id": .string(windowID.uuidString),
            ]
        ))

        #expect(result == .ok(.object([:])))
        #expect(context.postedEvents.count == 1)
        #expect(context.postedEvents[0].0 == .setQuery("update"))
        #expect(context.postedEvents[0].1 == windowID)
    }

    @Test func querySetRequiresQuery() {
        let (coordinator, context) = makeCoordinator()

        #expect(
            coordinator.handle(request("debug.command_palette.query.set"))
                == .err(code: "invalid_params", message: "Missing query", data: nil)
        )
        #expect(context.postedEvents.isEmpty)
    }

    @Test func submitTargetsExactWindow() {
        let (coordinator, context) = makeCoordinator()
        let windowID = UUID()

        let result = coordinator.handle(request(
            "debug.command_palette.submit",
            ["window_id": .string(windowID.uuidString)]
        ))

        #expect(result == .ok(.object([:])))
        #expect(context.postedEvents.count == 1)
        #expect(context.postedEvents[0].0 == .submit)
        #expect(context.postedEvents[0].1 == windowID)
    }
}
#endif
