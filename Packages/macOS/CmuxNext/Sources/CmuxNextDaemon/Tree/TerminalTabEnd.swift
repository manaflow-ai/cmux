import Foundation

/// Whether a terminal tab's shell runs, and why a dead one ended (R41,
/// plans/cmux-next/durable-sessions.md section 7). Wire `terminal_state`.
public enum TerminalTabState: String, Sendable, Hashable, Decodable {
    case running
    /// A restarted daemon is still adopting the terminal's host; the shell runs.
    case adopting
    /// The host's record is one this daemon build cannot adopt; the shell may
    /// still run until the user closes the tab.
    case unadoptable
    /// The daemon lost its link to the terminal's host and is reconnecting.
    case reconnecting
    /// The daemon gave up reconnecting to the host; the shell may still run.
    case failed
    case exited
}

// TerminalTabEnd, its cause and its enums are generated from the schema (swift_app codegen, Tree family);
// the nested names stay for the app's call sites.
extension TerminalTabEnd {
    public typealias Kind = TerminalEndKind
    public typealias HostLostReason = TerminalHostLostReason
    public typealias LaunchFailure = TerminalLaunchFailure
    public typealias Cause = TerminalLossCause
}
