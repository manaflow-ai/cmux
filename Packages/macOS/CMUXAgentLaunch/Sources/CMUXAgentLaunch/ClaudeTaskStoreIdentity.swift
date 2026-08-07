import CryptoKit
import Foundation

/// An opaque, deterministic namespace for one Claude task-store root.
///
/// Claude supports independent profiles through `CLAUDE_CONFIG_DIR`. Their
/// task directories may use the same session or team names, so consumers must
/// include the store root when persisting ownership outside that profile.
public struct ClaudeTaskStoreIdentity: Codable, Hashable, Sendable {
    /// The URL-safe digest used in persistence and checklist ownership keys.
    public let rawValue: String

    /// Creates the stable namespace for a resolved Claude tasks directory.
    ///
    /// - Parameter tasksRootURL: The profile's resolved `tasks` directory.
    public init(tasksRootURL: URL) {
        let canonicalRootURL = tasksRootURL.canonicalClaudeTaskStoreDirectoryURL
        let payload = Data("cmux.claude-task-store.v1\0\(canonicalRootURL.path)".utf8)
        rawValue = Data(SHA256.hash(data: payload))
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }
}
