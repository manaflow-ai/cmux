public import Foundation

/// What a tab's hover card says about the tab beyond its title (Leo 2026-10-14, like a
/// browser's tab preview): what kind of tab it is, what it is doing and since when, the
/// agent's model and the git branch. The App fills it from daemon and
/// acpmux records; the card's memory comes from its live sample.
public struct TabHoverFacts: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case other, terminal, browser, agentChat
    }

    /// What the tab is doing, as its card words it.
    public enum Activity: Hashable, Sendable {
        case working, needsInput, idle, failed, running
    }

    public var kind: Kind = .other
    public var activity: Activity?
    /// When `activity` began; the card says how long it has held.
    public var since: Date?
    /// The agent's model ("Opus 5.5").
    public var model: String?
    /// The git branch of the tab's folder.
    public var branch: String?
    /// When a plain shell at its prompt last printed (Leo 2026-10-21), or its prompt's start before
    /// any output is known; nil while it runs a command, for an agent and for a shell the daemon
    /// reports no prompt for.
    public var lastOutput: Date?

    public init(kind: Kind = .other, activity: Activity? = nil, since: Date? = nil, model: String? = nil,
                branch: String? = nil, lastOutput: Date? = nil) {
        self.kind = kind
        self.activity = activity
        self.since = since
        self.model = model
        self.branch = branch
        self.lastOutput = lastOutput
    }
}
