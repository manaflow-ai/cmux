import Foundation
import Testing
@testable import CmuxControlSocket

/// #13369: `surface.resume.set` reports a binding that still needs approval
/// instead of waiting on the app's approval prompt.
@MainActor
@Suite("ControlCommandCoordinator surface resume approval")
struct ControlCommandCoordinatorSurfaceResumeApprovalTests {
    @Test func surfaceResumeSetReportsApprovalRequired() {
        let (payload, _) = resumePayload(method: "surface.resume.set", approvalRequired: true)
        #expect(payload?["approval_required"] == .bool(true))
        #expect(payload?["resume_claimed"] == nil)
    }

    @Test func surfaceResumeGetOmitsApprovalRequired() {
        let (payload, _) = resumePayload(method: "surface.resume.get", approvalRequired: nil)
        #expect(payload != nil)
        #expect(payload?["approval_required"] == nil)
    }

    private func resumePayload(
        method: String,
        approvalRequired: Bool?
    ) -> ([String: JSONValue]?, FakeSurfaceControlCommandContext) {
        let context = FakeSurfaceControlCommandContext()
        let surfaceID = UUID()
        context.resumeResolution = .result(ControlSurfaceResumeSnapshot(
            windowID: nil,
            workspaceID: UUID(),
            paneID: nil,
            surfaceID: surfaceID,
            cleared: false,
            binding: nil,
            restoreRecord: nil,
            approvalRequired: approvalRequired
        ))
        let coordinator = ControlCommandCoordinator(context: context)
        let result = coordinator.handle(ControlRequest(
            id: .int(1),
            method: method,
            params: [
                "surface_id": .string(surfaceID.uuidString),
                "command": .string("tmux attach -t work"),
            ]
        ))
        guard case .ok(.object(let payload)) = result else {
            Issue.record("expected \(method) result, got \(result)")
            return (nil, context)
        }
        return (payload, context)
    }
}
