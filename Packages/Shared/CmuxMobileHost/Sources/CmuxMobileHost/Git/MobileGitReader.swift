import CmuxMobileWire

/// The session host's read-only git operations (`git.status`, `git.diff`;
/// cmux-tui `spec/resource-operations-v2.json`). The app implements it over
/// `GitResourceClient.read`; tests use a fake. `params` always carry the
/// canonical absolute `path` the policy accepted.
///
/// Throw `MobileDaemonError` with code `git.not_a_repo` when the session host
/// answers `operation.failed` with `details.extra.code = not_a_repository`;
/// any other failure is reported to the phone as `git.failed`.
public protocol MobileGitReader: Sendable {
    func read(_ operation: String, params: JSONValue) async throws -> JSONValue
}
