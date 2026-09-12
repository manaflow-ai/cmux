public import Foundation

/// The admission result returned by the workspace terminal font-size seam.
public enum ControlWorkspaceFontSizeResolution: Sendable, Equatable {
    case unavailable
    case notFound
    case rejected
    case accepted(workspaceID: UUID)
}
