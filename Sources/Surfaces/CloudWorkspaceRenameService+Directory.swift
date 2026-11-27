import Foundation

extension CloudWorkspaceRenameService {
    /// Applies accepted cmux-tui terminal cwd values to projected Cloud panels.
    ///
    /// - Parameters:
    ///   - localWorkspaceID: The local workspace whose projected panels are updated.
    ///   - catalog: The authoritative surface catalog containing projections and resources.
    @MainActor
    func updateCloudDirectories(localWorkspaceID: UUID, catalog: SurfaceCatalog) {
        catalog.updateCloudDirectoryMetadata(localWorkspaceID: localWorkspaceID)
    }
}
