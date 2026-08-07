internal import Foundation

/// A validated opaque identifier used to correlate native-attention messages.
public nonisolated struct AgentAttentionOpaqueIdentifier: Hashable, RawRepresentable, Sendable {
    /// The validated wire value.
    public let rawValue: String

    /// Validates and creates an opaque identifier.
    ///
    /// Values must be non-empty ASCII without whitespace or control characters
    /// and may contain at most 160 UTF-8 bytes.
    ///
    /// - Parameter rawValue: The untrusted wire value.
    public init?(rawValue: String) {
        let normalized = rawValue.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !normalized.isEmpty,
              normalized.utf8.count <= 160,
              normalized.unicodeScalars.allSatisfy({
                  $0.isASCII
                      && !$0.properties.isWhitespace
                      && !CharacterSet.controlCharacters.contains($0)
              }) else {
            return nil
        }
        self.rawValue = normalized
    }
}
