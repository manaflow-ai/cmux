import Foundation
import Testing
@testable import CmuxControlSocket

// Surface-domain default for fakes that do not drive the jump. Kept beside its
// tests because `ControlCommandContextTestStubs.swift` is over its line budget.
extension ControlSurfaceContext {
    func controlSurfaceJumpToLastPrompt() -> ControlSurfaceFocusResolution? { nil }
}

@MainActor
@Suite("ControlCommandCoordinator surface.jump_to_last_prompt")
struct ControlCommandCoordinatorJumpToLastPromptTests {
    private func run(
        _ method: String,
        params: [String: JSONValue] = [:],
        configure: (FakeSurfaceControlCommandContext) -> Void
    ) throws -> ControlCallResult {
        let context = FakeSurfaceControlCommandContext()
        configure(context)
        let coordinator = ControlCommandCoordinator(context: context)
        return try #require(coordinator.handle(ControlRequest(id: .int(1), method: method, params: params)))
    }

    @Test func reportsNotOpenedWhenNoSurfaceHasAPrompt() throws {
        let result = try run("surface.jump_to_last_prompt") { _ in }
        #expect(result == .ok(.object(["opened": .bool(false)])))
    }

    @Test func returnsTheFocusedSurfaceWhenATargetResolves() throws {
        let windowID = UUID()
        let workspaceID = UUID()
        let surfaceID = UUID()
        let result = try run("surface.jump_to_last_prompt") {
            $0.jumpToLastPromptResolution = .focused(
                windowID: windowID,
                workspaceID: workspaceID,
                surfaceID: surfaceID
            )
        }
        guard case .ok(.object(let payload)) = result else {
            Issue.record("expected an ok payload, got \(result)")
            return
        }
        #expect(payload["opened"] == .bool(true))
        #expect(payload["workspace_id"] == .string(workspaceID.uuidString))
        #expect(payload["surface_id"] == .string(surfaceID.uuidString))
        #expect(payload["window_id"] == .string(windowID.uuidString))
        #expect(payload["workspace_ref"] != nil)
        #expect(payload["surface_ref"] != nil)
    }

    @Test func dockFailureCarriesNoRequestedSurface() throws {
        let result = try run("surface.jump_to_last_prompt") {
            $0.jumpToLastPromptResolution = .dockUnavailable(message: "dock")
        }
        #expect(result == .err(code: "unavailable", message: "dock", data: nil))
    }

    /// `surface.focus` now shares the encoder; its Dock error still echoes the
    /// surface the caller asked for.
    @Test func surfaceFocusDockFailureStillEchoesTheRequestedSurface() throws {
        let surfaceID = UUID()
        let result = try run(
            "surface.focus",
            params: ["surface_id": .string(surfaceID.uuidString)]
        ) {
            $0.focusResolution = .dockUnavailable(message: "dock")
        }
        #expect(result == .err(
            code: "unavailable",
            message: "dock",
            data: .object(["surface_id": .string(surfaceID.uuidString)])
        ))
    }
}
