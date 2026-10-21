public import CmuxNextDaemon

/// A `cmux status run` that this client saw running and then saw finish
/// (plans/cmux-next/status-indicators.md section 5): the CLI writes its
/// `run:<pid>` workspace status entry busy, then success or error with the
/// command's exit code and duration. Pure.
public struct FinishedStatusRun: Hashable, Sendable {
    /// The workspace whose status holds the entry.
    public var workspace: ResourceID
    /// The entry's key (`run:<pid>`).
    public var key: String
    /// The run's label (`--label`, else the command).
    public var label: String
    /// The terminal the run is about (`target_terminal`), nil for a run started outside cmux.
    public var terminal: String?
    /// The command exited 0.
    public var succeeded: Bool
    /// The command's exit status (128 + the signal for a signal), nil when the CLI sent none.
    public var exitCode: Int?
    /// How long the command ran, nil when the CLI sent no duration (it could not start).
    public var durationMs: UInt64?

    public init(workspace: ResourceID, key: String, label: String, terminal: String? = nil, succeeded: Bool,
                exitCode: Int? = nil, durationMs: UInt64? = nil) {
        self.workspace = workspace
        self.key = key
        self.label = label
        self.terminal = terminal
        self.succeeded = succeeded
        self.exitCode = exitCode
        self.durationMs = durationMs
    }
}
