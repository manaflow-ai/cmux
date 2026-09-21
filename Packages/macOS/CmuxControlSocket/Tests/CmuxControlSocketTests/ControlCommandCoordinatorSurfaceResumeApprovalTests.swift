import Foundation
import Testing
@testable import CmuxControlSocket

/// `surface.resume.set` must answer immediately and tell the client whether
/// the user's "Allow Resume Command?" decision is still outstanding, instead
/// of parking the command behind an app-modal alert on the main thread
/// (https://github.com/manaflow-ai/cmux/issues/13369).
@MainActor
@Suite("ControlCommandCoordinator surface.resume.set approval reporting")
struct ControlCommandCoordinatorSurfaceResumeApprovalTests {
    private func makeSnapshot() -> ControlSurfaceResumeSnapshot {
        ControlSurfaceResumeSnapshot(
            windowID: UUID(),
            workspaceID: UUID(),
            paneID: UUID(),
            surfaceID: UUID(),
            cleared: false,
            binding: nil,
            restoreRecord: nil,
            resumeClaimed: nil
        )
    }

    private func resumeSetPayload(
        _ context: FakeSurfaceControlCommandContext
    ) throws -> [String: JSONValue] {
        let coordinator = ControlCommandCoordinator(context: context)
        let result = coordinator.handle(ControlRequest(
            id: .int(1),
            method: "surface.resume.set",
            params: [
                "command": .string("tmux attach -t work"),
                "source": .string("manual"),
            ]
        ))
        guard case .ok(.object(let payload))? = result else {
            Issue.record("expected an ok payload, got \(String(describing: result))")
            return [:]
        }
        return payload
    }

    @Test func resumeSetReportsWhenNoApprovalDecisionIsOutstanding() throws {
        let context = FakeSurfaceControlCommandContext()
        context.resumeResolution = .result(makeSnapshot())

        let payload = try resumeSetPayload(context)

        // The reply must say whether cmux still owes the user a decision. Before
        // the fix the key does not exist: the decision was taken inline by an
        // app-modal alert that blocked the main actor for every other command.
        #expect(payload["approval_prompt_pending"] == .bool(false))
    }
}
