/// A workspace's todo lifecycle lane, shown in the sidebar and settable over
/// the control socket / CLI. Raw values are a control-socket and session
/// wire format; frozen.
public enum WorkspaceTaskStatus: String, Codable, CaseIterable, Sendable {
    case todo
    case working
    case needsAttention = "needs-attention"
    case review
    case done

    /// The status inferred from live workspace signals, first match wins:
    /// an agent waiting on input beats a running agent, which beats an open
    /// PR, which beats an all-merged/closed PR set, which beats a dirty
    /// working tree; a workspace with none of these is plain `todo`.
    ///
    /// - Parameter signals: The live signals sampled from the workspace.
    /// - Returns: The inferred status.
    public static func inferred(from signals: WorkspaceTaskStatusSignals) -> WorkspaceTaskStatus {
        if signals.anyAgentNeedsInput { return .needsAttention }
        if signals.anyAgentRunning { return .working }
        if signals.anyOpenPullRequest { return .review }
        if signals.hasPullRequests && signals.allPullRequestsMergedOrClosed { return .done }
        if signals.isGitDirty { return .working }
        return .todo
    }

    /// The next lane in round-robin declaration order
    /// (todo → working → needs-attention → review → done → todo), used by the
    /// `cycleWorkspaceStatus` shortcut / `workspace.status.cycle` verb.
    public var next: WorkspaceTaskStatus {
        let all = WorkspaceTaskStatus.allCases
        guard let index = all.firstIndex(of: self) else { return .todo }
        return all[(index + 1) % all.count]
    }
}
