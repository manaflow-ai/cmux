import Foundation
import Testing
@testable import CmuxControlSocket

@MainActor
@Suite("ControlCommandCoordinator surface.read_text")
struct ControlCommandCoordinatorSurfaceReadTextTests {
    private func makeCoordinator() -> (ControlCommandCoordinator, FakeSurfaceReadTextControlCommandContext) {
        let context = FakeSurfaceReadTextControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)
        return (coordinator, context)
    }

    private func request(_ method: String, _ params: [String: JSONValue] = [:]) -> ControlRequest {
        ControlRequest(id: .int(1), method: method, params: params)
    }

    @Test func terminalNotReadyIsRetryableErrorWithSurfaceID() {
        let (coordinator, context) = makeCoordinator()
        let surfaceID = UUID()
        context.readResolution = .terminalNotReady(surfaceID)

        let result = coordinator.handle(request("surface.read_text", [
            "surface_id": .string(surfaceID.uuidString),
            "lines": .int(20),
        ]))

        #expect(context.lastRead?.surfaceID == surfaceID)
        #expect(context.lastRead?.hasSurfaceIDParam == true)
        #expect(context.lastRead?.includeScrollback == true)
        #expect(context.lastRead?.lineLimit == 20)
        #expect(context.lastRead?.startIfNeeded == false)
        #expect(result == .err(
            code: "terminal_not_ready",
            message: "Terminal surface is starting",
            data: .object(["surface_id": .string(surfaceID.uuidString)])
        ))
    }

    @Test func startIfNeededFalseIsForwarded() {
        let (coordinator, context) = makeCoordinator()
        let surfaceID = UUID()
        context.readResolution = .terminalNotReady(surfaceID)

        _ = coordinator.handle(request("surface.read_text", [
            "surface_id": .string(surfaceID.uuidString),
            "start_if_needed": .bool(false),
        ]))

        #expect(context.lastRead?.surfaceID == surfaceID)
        #expect(context.lastRead?.includeScrollback == false)
        #expect(context.lastRead?.lineLimit == nil)
        #expect(context.lastRead?.startIfNeeded == false)
    }

    @Test func startIfNeededTrueIsForwarded() {
        let (coordinator, context) = makeCoordinator()
        let surfaceID = UUID()
        context.readResolution = .terminalNotReady(surfaceID)

        _ = coordinator.handle(request("surface.read_text", [
            "surface_id": .string(surfaceID.uuidString),
            "start_if_needed": .bool(true),
        ]))

        #expect(context.lastRead?.surfaceID == surfaceID)
        #expect(context.lastRead?.startIfNeeded == true)
    }
}
