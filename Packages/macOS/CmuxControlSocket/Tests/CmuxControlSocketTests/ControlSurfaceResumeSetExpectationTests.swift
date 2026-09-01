import Foundation
import Testing
@testable import CmuxControlSocket

@Suite("Surface resume conditional set inputs")
@MainActor
struct ControlSurfaceResumeSetExpectationTests {
    @Test
    func parsesExpectedGeneration() throws {
        let context = FakeSurfaceControlCommandContext()
        context.resumeResolution = .setFailed
        let coordinator = ControlCommandCoordinator(context: context)

        _ = coordinator.handle(ControlRequest(
            id: .int(1),
            method: "surface.resume.set",
            params: [
                "command": .string("claude --resume session-a"),
                "_cmux_expected_binding_updated_at": .double(42.5),
                "_cmux_expect_missing_binding": .bool(false),
            ]
        ))

        let inputs = try #require(context.resumeSetInputs)
        #expect(inputs.expectedBindingUpdatedAt == 42.5)
        #expect(!inputs.expectsMissingBinding)
    }

    @Test
    func parsesMissingBindingExpectation() throws {
        let context = FakeSurfaceControlCommandContext()
        context.resumeResolution = .setFailed
        let coordinator = ControlCommandCoordinator(context: context)

        _ = coordinator.handle(ControlRequest(
            id: .int(1),
            method: "surface.resume.set",
            params: [
                "command": .string("claude --resume session-a"),
                "_cmux_expect_missing_binding": .bool(true),
            ]
        ))

        let inputs = try #require(context.resumeSetInputs)
        #expect(inputs.expectedBindingUpdatedAt == nil)
        #expect(inputs.expectsMissingBinding)
    }

    @Test
    func rejectsConflictingExpectations() {
        let context = FakeSurfaceControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)

        let result = coordinator.handle(ControlRequest(
            id: .int(1),
            method: "surface.resume.set",
            params: [
                "command": .string("claude --resume session-a"),
                "_cmux_expected_binding_updated_at": .double(42.5),
                "_cmux_expect_missing_binding": .bool(true),
            ]
        ))

        #expect(result == .err(
            code: "internal_error",
            message: "Failed to set resume binding",
            data: nil
        ))
        #expect(context.resumeSetInputs == nil)
    }
}
