/// The result of resolving a cmux wrapper launcher to its fork command.
public enum AgentForkLauncherResolution: Sendable, Equatable {
    /// The launcher is a cmux wrapper; the associated value is its fork argv, or `nil` when
    /// the wrapper has no forkable form.
    case resolved([String]?)

    /// The launcher is a plain agent executable; fall through to
    /// ``AgentForkArgv/builtInKind(kind:sessionId:executablePath:arguments:)``.
    case passthrough
}
