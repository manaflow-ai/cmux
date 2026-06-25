/// How a `cmux.json` notification-hook list combines with hooks resolved from
/// less specific config scopes.
///
/// Parsed from the `hooksMode` key of a `CmuxNotificationConfigDefinition`.
public enum CmuxNotificationHooksMode: String, Codable, Sendable, Hashable {
    /// Append this scope's hooks to those inherited from broader scopes.
    case append
    /// Replace any inherited hooks with this scope's hooks.
    case replace
}
