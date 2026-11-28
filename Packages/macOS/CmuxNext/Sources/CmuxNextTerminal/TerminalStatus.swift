/// OSC 9;4 progress (`GHOSTTY_ACTION_PROGRESS_REPORT`).
public nonisolated enum TerminalProgress: Sendable, Equatable {
    /// 0...100 when the program reported a value.
    case normal(Int?)
    case error(Int?)
    case paused(Int?)
    case indeterminate
}

/// Result of a shell command reported through OSC 133 (`COMMAND_FINISHED`).
public nonisolated struct TerminalCommandResult: Sendable, Equatable {
    public var exitCode: Int?
    public var duration: Duration
}

/// Scroll position of the viewport in the scrollback (`SCROLLBAR`).
public nonisolated struct TerminalScrollbar: Sendable, Equatable {
    public var totalRows: UInt64
    public var offsetRows: UInt64
    public var visibleRows: UInt64
}
