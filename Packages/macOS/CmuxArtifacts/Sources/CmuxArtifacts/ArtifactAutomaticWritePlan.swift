import Foundation

/// Exact automatic destinations authorized before an import batch persists files.
struct ArtifactAutomaticWritePlan {
    let destinations: [URL]
    let copyDestinationBySnapshotPath: [String: URL]
    let captureResolution: ArtifactCaptureDirectoryResolution?

    func copyDestination(for prepared: PreparedArtifactImport) -> URL? {
        copyDestinationBySnapshotPath[prepared.snapshot.url.standardizedFileURL.path]
    }
}
