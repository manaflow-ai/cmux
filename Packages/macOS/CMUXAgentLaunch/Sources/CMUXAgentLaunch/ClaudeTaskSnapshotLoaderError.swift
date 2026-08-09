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
    /// One decoded task text field exceeded its hard UTF-8 byte limit.
    case taskTextTooLarge(fileName: String, field: String, limit: Int)
    /// The live task text retained by one snapshot exceeded its aggregate limit.
    case snapshotTextTooLarge(limit: Int)
    /// A known task-list path existed but was not a direct, non-symlink directory.
    case invalidTaskDirectory(directoryName: String)
    /// The team-store root could not be enumerated while resolving an agent.
    case cannotEnumerateTeamsRoot
    /// The shallow team-root scan exceeded its hard entry limit.
    case tooManyTeamRootEntries(limit: Int)
    /// A team configuration file exceeded its hard byte limit.
    case teamConfigFileTooLarge(fileName: String, limit: Int)
    /// More than one team configuration claimed the same exact hook agent.
    case ambiguousTeamMembership
    /// A matching team configuration did not own its canonical directory.
    case invalidTeamDirectoryBinding
    /// Team metadata changed while one bounded identity scan was in progress.
    case teamConfigurationChangedDuringScan
    /// The caller's monotonic task-operation deadline elapsed.
    case operationDeadlineExceeded
}
