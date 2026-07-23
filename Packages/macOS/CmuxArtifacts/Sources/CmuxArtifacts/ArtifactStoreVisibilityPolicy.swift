import Foundation

/// Defines which live `.cmux` entries are user-visible Notes and Artifacts.
struct ArtifactStoreVisibilityPolicy {
    func isManagedEntry(_ url: URL, filesystemRoot: URL) -> Bool {
        if url.lastPathComponent == ArtifactPathResolver.workspaceMarkerName
            || url.lastPathComponent == ArtifactPathResolver.sessionMarkerName {
            return true
        }
        let resolver = ArtifactPathResolver()
        if resolver.refersToSameLocation(
            url,
            filesystemRoot.appendingPathComponent(".metadata", isDirectory: true)
        ) {
            return true
        }
        guard url.deletingLastPathComponent().standardizedFileURL
            == filesystemRoot.standardizedFileURL else {
            return false
        }
        return url.lastPathComponent.hasPrefix(".")
            || ArtifactStorePaths.trackableControlFileNames.contains(url.lastPathComponent)
    }
}
