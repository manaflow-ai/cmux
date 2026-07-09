/// How a `cmux.json` file's notification hooks combine with hooks inherited from
/// higher-precedence configuration.
///
/// `append` adds this file's hooks to the already-resolved set; `replace` clears
/// the inherited hooks first so only this file's hooks apply. The wire value is
/// the lowercased case name (`"append"` / `"replace"`).
public enum CmuxNotificationHooksMode: String, Codable, Sendable, Hashable {
    /// Add this file's hooks to the inherited set.
    case append
    /// Discard inherited hooks, keeping only this file's hooks.
    case replace
}
