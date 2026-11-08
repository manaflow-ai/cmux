/// Resolves the immutable filesystem-event plan for a Git working tree.
public protocol GitMetadataWatchDescriptorReading: Sendable {
    /// Returns the watch descriptor for `directory`, or `nil` outside a repository.
    func watchDescriptor(for directory: String) async -> GitWorkspaceMetadataWatchDescriptor?
}

extension GitMetadataService: GitMetadataWatchDescriptorReading {}
