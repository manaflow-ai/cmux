import Foundation

/// Immutable identity used to restart artifact-sidebar workspace binding.
struct ArtifactSidebarBinding: Equatable {
    let workspaceID: String?
    let workingDirectory: URL?
    let isVisible: Bool
}
