public import Foundation

/// How a `command` block in `cmux.json` behaves when its target workspace
/// already exists: open a `new` workspace, `recreate` the existing one, `ignore`
/// the invocation, or `confirm` with the user before acting.
///
/// This is the `Codable`, `Sendable` wire image consumed by
/// ``CmuxCommandDefinition``; the raw values are part of the `cmux.json` schema
/// and must stay byte-stable.
public enum CmuxRestartBehavior: String, Codable, Sendable {
    /// Open a new workspace, leaving any existing match untouched.
    case new
    /// Recreate the existing matching workspace.
    case recreate
    /// Ignore the invocation when a matching workspace already exists.
    case ignore
    /// Confirm with the user before acting.
    case confirm
}
