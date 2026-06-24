public import Foundation

/// One candidate transcript file gathered while resolving a registered agent's
/// sessions: the file URL, its content-modification date, and whether ripgrep
/// pre-filtered it for the search needle (so the app loader can skip the
/// Foundation `fileContains` re-check).
///
/// Package-owned `Sendable` value type produced by
/// ``RegisteredAgentSessionResolver/gatherRegisteredJSONLCandidates(roots:needle:)``;
/// the app loader sorts these by date, applies the cancellation/scan caps, and
/// maps each surviving candidate onto a `SessionEntry`.
public struct RegisteredAgentSessionCandidate: Sendable, Hashable {
    /// The candidate transcript file.
    public let url: URL
    /// The file's content-modification date.
    public let modified: Date
    /// Whether ripgrep already confirmed the file contains the needle, so the
    /// loader can skip the Foundation content re-check.
    public let prefilteredByRipgrep: Bool

    /// Creates a candidate.
    ///
    /// - Parameters:
    ///   - url: The candidate transcript file.
    ///   - modified: The file's content-modification date.
    ///   - prefilteredByRipgrep: Whether ripgrep already matched the needle.
    public init(url: URL, modified: Date, prefilteredByRipgrep: Bool) {
        self.url = url
        self.modified = modified
        self.prefilteredByRipgrep = prefilteredByRipgrep
    }
}

/// One candidate Grok `chat_history.jsonl` file gathered while resolving a
/// Grok-backed agent's sessions: the base candidate fields plus the
/// ``GrokSessionRoot`` it was enumerated under (needed app-side to reconstruct
/// the `GROK_HOME`-prefixed resume command).
///
/// Package-owned `Sendable` value type produced by
/// ``RegisteredAgentSessionResolver/gatherGrokHistoryCandidates(roots:needle:fileManager:)``;
/// the app loader sorts these by date, applies the cancellation/scan caps, and
/// maps each surviving candidate onto a `SessionEntry`.
public struct GrokSessionCandidate: Sendable, Hashable {
    /// The candidate `chat_history.jsonl` file.
    public let url: URL
    /// The file's content-modification date.
    public let modified: Date
    /// Whether ripgrep already confirmed the file contains the needle, so the
    /// loader can skip the Foundation content re-check.
    public let prefilteredByRipgrep: Bool
    /// The Grok session root the candidate was enumerated under.
    public let root: GrokSessionRoot

    /// Creates a candidate.
    ///
    /// - Parameters:
    ///   - url: The candidate `chat_history.jsonl` file.
    ///   - modified: The file's content-modification date.
    ///   - prefilteredByRipgrep: Whether ripgrep already matched the needle.
    ///   - root: The Grok session root the candidate was enumerated under.
    public init(url: URL, modified: Date, prefilteredByRipgrep: Bool, root: GrokSessionRoot) {
        self.url = url
        self.modified = modified
        self.prefilteredByRipgrep = prefilteredByRipgrep
        self.root = root
    }
}
