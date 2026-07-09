import Foundation

/// A resolved Grok sessions directory plus the `GROK_HOME` to use when resuming
/// sessions discovered under it.
///
/// `sessionsRoot` is the absolute, tilde-expanded path of a `.../sessions`
/// directory to scan. `grokHomeForResume` is the parent of a non-default
/// sessions root (the value to pass as `GROK_HOME` when resuming), or `nil`
/// when the root is the default location and needs no override.
public struct GrokSessionRoot: Sendable, Hashable {
    /// Absolute path of the `.../sessions` directory to scan.
    public let sessionsRoot: String
    /// `GROK_HOME` override to apply when resuming sessions found under
    /// `sessionsRoot`, or `nil` for the default location.
    public let grokHomeForResume: String?

    /// Creates a resolved Grok sessions root.
    public init(sessionsRoot: String, grokHomeForResume: String?) {
        self.sessionsRoot = sessionsRoot
        self.grokHomeForResume = grokHomeForResume
    }
}
