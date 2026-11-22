/// What an engine reports to its host, in order: scene batches per mount,
/// log lines, and its stop. Hosts route mounts to their scene models.
public nonisolated enum AppEngineOutput: Sendable, Hashable {
    case scene(mount: String, ops: [AppSceneOp])
    case log(level: String, message: String)
    case stopped(reason: String)
}

/// Engine state.
public nonisolated enum AppEngineState: Sendable, Hashable {
    case idle
    case running
    /// Stopped by `stop()`, a load failure, or a limit (the reason says which).
    case stopped(String)
}
