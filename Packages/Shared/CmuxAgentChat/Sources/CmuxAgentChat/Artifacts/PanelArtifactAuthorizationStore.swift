import Foundation

/// Retains the single canonical file currently exposed by each file-backed panel.
@MainActor
public final class PanelArtifactAuthorizationStore {
    private struct GrantKey: Hashable {
        let workspaceID: String
        let surfaceID: String
    }

    private let resolver: any ChatArtifactScope.FileSystemResolving
    private var canonicalPathByGrantKey: [GrantKey: String] = [:]

    /// Creates a lifecycle-bound panel grant registry.
    ///
    /// - Parameter resolver: Filesystem resolver used for both grant-time and
    ///   request-time canonicalization.
    public init(
        resolver: any ChatArtifactScope.FileSystemResolving = ChatArtifactScope.FoundationResolver()
    ) {
        self.resolver = resolver
    }

    /// Replaces one panel's grant with its current canonical file path.
    ///
    /// A failed canonicalization removes any previous grant for the same panel,
    /// so an unavailable replacement can never preserve access to the old file.
    ///
    /// - Parameters:
    ///   - workspaceID: Workspace containing the panel.
    ///   - surfaceID: Stable panel surface identifier.
    ///   - filePath: File path currently displayed by the panel.
    /// - Returns: The canonical path that was recorded, or `nil` when the path
    ///   could not be canonicalized.
    @discardableResult
    public func record(
        workspaceID: String,
        surfaceID: String,
        filePath: String
    ) -> String? {
        let key = GrantKey(workspaceID: workspaceID, surfaceID: surfaceID)
        guard let canonicalPath = ChatArtifactScope.canonicalizedPath(
            filePath,
            resolver: resolver
        ) else {
            canonicalPathByGrantKey.removeValue(forKey: key)
            return nil
        }
        canonicalPathByGrantKey[key] = canonicalPath
        return canonicalPath
    }

    /// Invalidates the file grant for one closed or replaced panel.
    ///
    /// - Parameters:
    ///   - workspaceID: Workspace that contained the panel.
    ///   - surfaceID: Closed or replaced panel surface identifier.
    public func invalidate(workspaceID: String, surfaceID: String) {
        canonicalPathByGrantKey.removeValue(
            forKey: GrantKey(workspaceID: workspaceID, surfaceID: surfaceID)
        )
    }

    /// Resolves a request only when it canonicalizes to the panel's one-file grant.
    ///
    /// - Parameters:
    ///   - workspaceID: Workspace containing the panel.
    ///   - surfaceID: Panel authorizing the request.
    ///   - requestedPath: Absolute path requested by the mobile client.
    /// - Returns: The canonical requested path when it exactly matches the live
    ///   grant, otherwise `nil`.
    public func authorizedCanonicalPath(
        workspaceID: String,
        surfaceID: String,
        requestedPath: String
    ) -> String? {
        let key = GrantKey(workspaceID: workspaceID, surfaceID: surfaceID)
        guard let grantedPath = canonicalPathByGrantKey[key],
              let requestedCanonicalPath = ChatArtifactScope.canonicalizedPath(
                requestedPath,
                resolver: resolver
              ),
              requestedCanonicalPath == grantedPath else {
            return nil
        }
        return requestedCanonicalPath
    }

    /// Resolves a request only when both the live panel path and request still
    /// canonicalize to the recorded grant.
    ///
    /// This comparison deliberately does not replace the grant. A symlink that
    /// is retargeted after grant time must revoke access until the panel
    /// lifecycle records a new file, rather than silently authorizing the new
    /// target during a read.
    ///
    /// - Parameters:
    ///   - workspaceID: Workspace containing the panel.
    ///   - surfaceID: Panel authorizing the request.
    ///   - currentFilePath: File path the live panel reports displaying.
    ///   - requestedPath: Absolute path requested by the mobile client.
    /// - Returns: The canonical requested path when the live panel and request
    ///   both exactly match the recorded grant, otherwise `nil`.
    public func authorizedCanonicalPath(
        workspaceID: String,
        surfaceID: String,
        currentFilePath: String,
        requestedPath: String
    ) -> String? {
        let key = GrantKey(workspaceID: workspaceID, surfaceID: surfaceID)
        guard let grantedPath = canonicalPathByGrantKey[key],
              let currentCanonicalPath = ChatArtifactScope.canonicalizedPath(
                currentFilePath,
                resolver: resolver
              ),
              currentCanonicalPath == grantedPath,
              let requestedCanonicalPath = ChatArtifactScope.canonicalizedPath(
                requestedPath,
                resolver: resolver
              ),
              requestedCanonicalPath == grantedPath else {
            return nil
        }
        return requestedCanonicalPath
    }
}
