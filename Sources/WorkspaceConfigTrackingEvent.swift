import Foundation

nonisolated enum WorkspaceConfigTrackingEvent: Equatable, Sendable {
    case panelDirectoryChanged(UUID)
    case workspaceDirectoryChanged
    case structuralChanged
}
