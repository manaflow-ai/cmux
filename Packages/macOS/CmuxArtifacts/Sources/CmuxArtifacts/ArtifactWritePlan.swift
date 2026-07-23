import Foundation

/// Exact destinations authorized before an import batch persists files.
struct ArtifactWritePlan {
    let destinations: [URL]
    let copyDestinationBySnapshotPath: [String: URL]
    let captureResolution: ArtifactCaptureDirectoryResolution?

    func copyDestination(for prepared: PreparedArtifactImport) -> URL? {
        copyDestinationBySnapshotPath[prepared.snapshot.url.standardizedFileURL.path]
    }

    /// Returns whether every destination in a refreshed plan was already Git-authorized.
    func authorizes(_ refreshed: ArtifactWritePlan) -> Bool {
        let authorizedPaths = Set(destinations.map { $0.standardizedFileURL.path })
        return refreshed.destinations.allSatisfy {
            authorizedPaths.contains($0.standardizedFileURL.path)
        }
    }
}
