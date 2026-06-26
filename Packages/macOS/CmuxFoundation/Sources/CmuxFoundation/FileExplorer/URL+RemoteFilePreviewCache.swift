public import Foundation

extension URL {
    /// Builds the on-disk cache location for a remote file materialized for preview
    /// by ``FileExplorerStore``. The path is
    /// `<temp>/cmux-remote-file-previews/<sanitized-displayTarget>/<filename>`, where
    /// `filename` is the sanitized remote path, suffixed with the remote file's
    /// last path component when that component is non-empty (`<sanitized-remote>-<basename>`).
    public static func remoteFilePreviewCache(displayTarget: String, remotePath: String) -> URL {
        let cacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-remote-file-previews", isDirectory: true)
        let target = displayTarget.sanitizedRemoteFilePreviewCacheComponent
        let remote = remotePath.sanitizedRemoteFilePreviewCacheComponent
        let basename = URL(fileURLWithPath: remotePath).lastPathComponent
        let filename = basename.isEmpty ? remote : "\(remote)-\(basename)"
        return cacheRoot
            .appendingPathComponent(target, isDirectory: true)
            .appendingPathComponent(filename, isDirectory: false)
    }
}

private extension String {
    /// Returns `self` reduced to a filesystem-safe cache path component: every
    /// character outside `[A-Za-z0-9._-]` becomes `-`, surrounding `-` are trimmed,
    /// the result is capped at 160 characters, and an empty result falls back to a
    /// fresh UUID string so the component is never empty.
    var sanitizedRemoteFilePreviewCacheComponent: String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let scalars = unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let candidate = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return candidate.isEmpty ? UUID().uuidString : String(candidate.prefix(160))
    }
}
