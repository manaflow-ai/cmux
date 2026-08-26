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

    /// Restores an identity previously persisted by cmux.
    ///
    /// The raw value is intentionally opaque: callers should pass values read
    /// from durable ownership records rather than constructing new namespaces.
    ///
    /// - Parameter persistedRawValue: The persisted URL-safe identity digest.
    /// - Returns: `nil` when the persisted value is empty or unreasonably large.
    public init?(persistedRawValue: String) {
        let normalized = persistedRawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized.utf8.count <= 128 else { return nil }
        self.rawValue = normalized
    }

    /// Creates the stable namespace for a resolved Claude tasks directory.
    ///
    /// - Parameter tasksRootURL: The profile's resolved `tasks` directory.
    /// - Parameter hostNamespace: Optional remote-host namespace for relay-backed
    ///   sessions whose remote paths may match another host's path.
    public init(tasksRootURL: URL, hostNamespace: String? = nil) {
        let canonicalRootURL = tasksRootURL.canonicalClaudeTaskStoreDirectoryURL
        let normalizedHostNamespace = hostNamespace?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let payloadString: String
        if let normalizedHostNamespace, !normalizedHostNamespace.isEmpty {
            payloadString = "cmux.claude-task-store.v2\0\(normalizedHostNamespace)\0\(canonicalRootURL.path)"
        } else {
            // Preserve the v1 digest for local profiles so existing durable
            // ownership records remain valid across upgrades.
            payloadString = "cmux.claude-task-store.v1\0\(canonicalRootURL.path)"
        }
        let payload = Data(payloadString.utf8)
        rawValue = Data(SHA256.hash(data: payload))
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }
}
