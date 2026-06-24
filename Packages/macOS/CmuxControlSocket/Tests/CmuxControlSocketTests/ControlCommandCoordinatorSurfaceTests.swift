import Foundation
import Testing
@testable import CmuxControlSocket

@MainActor
private final class FakeSurfaceControlCommandContext: ControlCommandContext {
    var reportPWDResolution: ControlSurfaceReportPWDResolution = .recorded(surfaceID: UUID())
    var reportedPWD: (workspaceID: UUID, requestedSurfaceID: UUID?, path: String)?

    func controlSurfaceReportPWD(
        workspaceID: UUID,
        requestedSurfaceID: UUID?,
        path: String
    ) -> ControlSurfaceReportPWDResolution {
        reportedPWD = (workspaceID, requestedSurfaceID, path)
        return reportPWDResolution
    }
}

@MainActor
@Suite("ControlCommandCoordinator surface domain")
struct ControlCommandCoordinatorSurfaceTests {
    private func makeCoordinator() -> (ControlCommandCoordinator, FakeSurfaceControlCommandContext) {
        let context = FakeSurfaceControlCommandContext()
        return (ControlCommandCoordinator(context: context), context)
    }

    private func request(_ params: [String: JSONValue]) -> ControlRequest {
        ControlRequest(id: .int(1), method: "surface.report_pwd", params: params)
    }

    @Test func reportPWDRejectsConflictingPathAliases() {
        let (coordinator, context) = makeCoordinator()
        let workspaceID = UUID()
        let result = coordinator.handle(request([
            "workspace_id": .string(workspaceID.uuidString),
            "path": .string("/srv/work/bar"),
            "cwd": .string("/srv/work/other"),
        ]))

        #expect(result == .err(code: "invalid_params", message: "Conflicting path parameters", data: nil))
        #expect(context.reportedPWD?.path == nil)
    }

    @Test func reportPWDPreservesExactPathWhitespace() {
        let (coordinator, context) = makeCoordinator()
        let workspaceID = UUID()
        _ = coordinator.handle(request([
            "workspace_id": .string(workspaceID.uuidString),
            "path": .string("/srv/work/bar "),
        ]))

        #expect(context.reportedPWD?.path == "/srv/work/bar ")
    }
}
