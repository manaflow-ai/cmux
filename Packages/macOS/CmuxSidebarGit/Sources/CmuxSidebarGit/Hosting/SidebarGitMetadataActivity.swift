/// The work level allowed for sidebar git metadata.
///
/// Visibility controls active filesystem/API polling independently from the
/// master git-watch preference. This keeps passive remote shell reports
/// available while their rows are hidden without spending background work.
public enum SidebarGitMetadataActivity: Equatable, Sendable {
    /// Reject passive reports, stop polling, and discard projected metadata.
    case disabled
    /// Accept passive reports and retain projections, but perform no polling.
    case passiveReportsOnly
    /// Accept passive reports and run active local metadata polling.
    case activePolling

    /// Whether shell/control-socket metadata reports should be accepted.
    public var acceptsPassiveReports: Bool {
        self != .disabled
    }

    /// Whether local filesystem metadata probes should run.
    public var performsActivePolling: Bool {
        self == .activePolling
    }
}
