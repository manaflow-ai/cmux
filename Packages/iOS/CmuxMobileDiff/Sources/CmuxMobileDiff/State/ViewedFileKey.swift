/// Content-sensitive identity for device-local viewed state.
struct ViewedFileKey: RawRepresentable, Sendable, Equatable, Hashable {
    /// Stable length-prefixed persistence representation.
    let rawValue: String

    /// Creates a key from an existing persistence representation.
    /// - Parameter rawValue: Previously encoded key.
    init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// Creates a key scoped by workspace, path, and patch digest.
    /// - Parameters:
    ///   - workspaceID: Workspace identity.
    ///   - path: Repository-relative path.
    ///   - patchDigest: Current patch digest.
    init(workspaceID: String, path: String, patchDigest: String) {
        rawValue = "\(workspaceID.count):\(workspaceID)\(path.count):\(path)\(patchDigest.count):\(patchDigest)"
    }
}
