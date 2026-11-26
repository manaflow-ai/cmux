/// In-flight state of one probe key's git or pull-request refresh.
///
/// `rerunPending` records that another refresh was requested while one was
/// already in flight, so the apply path schedules a follow-up instead of
/// dropping the request.
enum WorkspaceGitProbeState: Equatable {
    case idle
    case inFlight(rerunPending: Bool)
}
