/// Result of normalizing a summarizer response.
enum AutoNamingSanitizationOutcome: Equatable, Sendable {
    /// A new title should be applied.
    case title(String)
    /// The model explicitly kept the current title; apply idempotently so
    /// panel/tab title side effects still run for newly split workspaces.
    case unchanged(String)
    /// The response did not contain a usable title.
    case unusable
}
