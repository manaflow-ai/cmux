/// Resource-bound failures while loading one Claude task snapshot.
enum ClaudeTaskSnapshotLoaderError: Error, Equatable {
    /// The task-store root could not be enumerated while resolving a team directory.
    case cannotEnumerateTasksRoot
    /// The session directory could not be enumerated.
    case cannotEnumerateSessionDirectory
    /// The shallow task-root scan exceeded its hard entry limit.
    case tooManyTaskRootEntries(limit: Int)
    /// The shallow directory scan exceeded its hard entry limit.
    case tooManyDirectoryEntries(limit: Int)
    /// A task file exceeded its hard byte limit.
    case taskFileTooLarge(fileName: String, limit: Int)
}
