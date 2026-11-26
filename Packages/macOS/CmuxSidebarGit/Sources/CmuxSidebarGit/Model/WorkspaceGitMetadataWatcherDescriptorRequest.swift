/// An in-flight request to resolve a directory's watched-path descriptor
/// (the set of git paths the filesystem watcher should observe).
///
/// `generation` is a monotonically increasing stamp so a stale resolution
/// (the directory changed while paths were being resolved off-main) is
/// dropped instead of installing a watcher for the wrong directory.
struct WorkspaceGitMetadataWatcherDescriptorRequest: Equatable, Sendable {
    let generation: UInt64
    let directory: String
}
