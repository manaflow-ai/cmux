import Foundation
@testable import CmuxControlSocket

@MainActor
final class FakeSurfaceControlCommandContext: ControlCommandContext {
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

    // MARK: - read_text recording

    /// Whether the coordinator should consider a TabManager resolvable; read-text
    /// tests need this `true` so `surfaceReadText` reaches `controlSurfaceReadText`.
    var readTextResolvesTabManager = true

    /// The arguments the coordinator forwarded to ``controlSurfaceReadText``, so a
    /// test can assert how it derived `includeScrollback` / `lineLimit` from the
    /// request params.
    var readTextInvocation: (includeScrollback: Bool, lineLimit: Int?)?

    func controlSurfaceRoutingResolvesTabManager(routing: ControlRoutingSelectors) -> Bool {
        readTextResolvesTabManager
    }

    func controlSurfaceReadText(
        routing: ControlRoutingSelectors,
        surfaceID: UUID?,
        hasSurfaceIDParam: Bool,
        includeScrollback: Bool,
        lineLimit: Int?
    ) -> ControlSurfaceReadTextResolution {
        readTextInvocation = (includeScrollback, lineLimit)
        return .read(
            text: "",
            base64: "",
            windowID: nil,
            workspaceID: UUID(),
            surfaceID: surfaceID ?? UUID()
        )
    }
}
