/// Localized UI copy strings handed to the agent-session web renderer in its `app.context` reply.
///
/// The value type carries an opaque key→string map of already-resolved strings so that
/// `String(localized:)` stays app-side: the app resolves every string against the app bundle
/// (`Localizable.xcstrings`) and constructs this value, while the package only stores and
/// serializes the resolved map. Resolving inside the package would bind to the package bundle,
/// which lacks the keys, and silently drop every non-English translation.
public struct AgentSessionWebContextCopy: Sendable, Equatable {
    /// Resolved copy strings keyed by the renderer's copy key (e.g. `"start"`, `"rateLimitDaysFormat"`).
    public var entries: [String: String]

    /// Creates a copy table from already-resolved, localized strings.
    public init(entries: [String: String]) {
        self.entries = entries
    }

    /// The resolved key→string map for serialization into the `app.context` payload.
    public var dictionary: [String: String] { entries }
}
