public import CmuxNextDesign

/// Group by Status's marks on a workspace row (Debug `sidebar.groupByStatus`; `SidebarLayout.statusRows` sets them, no
/// other mode does): one status glyph per bucket, a trailing warning on Needs you rows, and where
/// the session runs (this Mac, a Cloud machine or another computer). From the row's merged status
/// and its section's machine only, so every harness draws the same marks.
public nonisolated struct WorkspaceRowStatusMarks: Hashable, Sendable {
    /// The bucket the row sits under (`SidebarGrouping.bucket`, the active row's held one included).
    public var bucket: SidebarStatusBucket
    /// The row's merged status (`SidebarWorkspace.activity`).
    public var activity: StatusIndicatorState
    /// The kind of computer the row's section is; nil outside a machine section.
    public var machine: SidebarMachine.Kind?

    public init(bucket: SidebarStatusBucket, activity: StatusIndicatorState, machine: SidebarMachine.Kind?) {
        self.bucket = bucket
        self.activity = activity
        self.machine = machine
    }

    /// What the shared status indicator draws for the bucket: the row's own state when it belongs
    /// there (an error stays an error, a known progress stays), the bucket's plain state when the
    /// row is held under a bucket it left, nil for a quiet glyph (Done without a reported success,
    /// No agent at rest).
    public var indicator: StatusIndicatorState? {
        switch (bucket, activity) {
        case (.needsYou, .waiting), (.needsYou, .error): activity
        case (.needsYou, _): .waiting(kind: nil)
        case (.working, .working), (.working, .busy), (.working, .paused): activity
        case (.working, _): .working(progress: nil)
        case (.done, .success): activity
        case (.noAgent, .busy), (.noAgent, .paused): activity
        case (.done, _), (.noAgent, _): nil
        }
    }

    /// Needs you rows end with a warning mark.
    public var warns: Bool { bucket == .needsYou }

    /// The urgent mark reads as an error for a failed row, else as waiting on the person.
    public var isError: Bool { if case .error = activity { true } else { false } }
}
