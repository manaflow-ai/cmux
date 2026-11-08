/// The result of resolving a user-supplied browser profile selector.
///
/// Selectors first match an existing profile UUID, then fall back to an exact,
/// case-insensitive display-name match.
public enum BrowserProfileSelectionResolution: Equatable, Sendable {
    /// The selector identified exactly one profile.
    case matched(BrowserProfileDefinition)
    /// No profile UUID or display name matched the selector.
    case notFound
    /// More than one profile has the requested display name.
    case ambiguous([BrowserProfileDefinition])
}
