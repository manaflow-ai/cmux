public import Foundation

/// One terminal tab of this Mac's daemon with what keeps its shell running, as the freeing tier reads it
/// (plans/cmux-next/sidebar-recents-and-freeing-DESIGN.md). ``DaemonParkableTerminals`` makes them.
public nonisolated struct DaemonTerminalFacts: Hashable, Sendable {
    /// The tab's surface id (what `park-tabs` takes).
    public var surface: String
    /// The workspace that holds it.
    public var workspace: String
    /// The workspace's newest sign of use; nil: none recorded.
    public var workspaceLastActive: Date?
    /// The workspace is pinned, runs something or needs attention.
    public var workspaceKept: Bool
    /// When the shell drew the prompt it sits at; nil: a command runs, or the shell sends no OSC 133.
    public var promptSince: Date?
    /// When the terminal last printed anything; nil: never.
    public var lastOutput: Date?
    /// An agent, or a program reporting its status (OSC 7501), runs in it.
    public var programReported: Bool
    /// It runs on this Mac (not an ssh or Cloud machine).
    public var local: Bool
    /// The shell already ended or the tab is already parked.
    public var ended: Bool
    /// A Claude Code or Codex TUI runs in it.
    public var runsAgent: Bool = false
    /// That agent is idle (no turn, nothing waits on the person) and its session id is recorded: showing the tab
    /// resumes it.
    public var agentResumable: Bool = false
    /// When the command that runs now started; nil: none runs, or the shell sends no OSC 133.
    public var commandSince: Date?
}
