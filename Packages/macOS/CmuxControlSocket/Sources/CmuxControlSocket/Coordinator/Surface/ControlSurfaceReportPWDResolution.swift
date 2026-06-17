public import Foundation

/// The outcome of `surface.report_pwd`. Mirrors `ControlSurfaceReportTTYResolution`
/// minus the `pending` case — pwd reports come from a live shell that already has
/// a known surface id, so a "remembered for later" path is not needed.
public enum ControlSurfaceReportPWDResolution: Sendable, Equatable {
    case workspaceNotFound
    case surfaceNotFound
    case recorded(surfaceID: UUID)
}
