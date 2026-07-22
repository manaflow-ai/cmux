import Foundation

/// Neutralizes terminal control characters in artifact-controlled human-readable text.
public struct ArtifactTerminalTextSanitizer: Sendable {
    /// Creates a stateless terminal-text sanitizer.
    public init() {}

    /// Replaces C0, DEL, and C1 controls with a visible replacement character.
    ///
    /// JSON and other machine-readable encodings should retain their raw values
    /// and must not pass through this presentation-only boundary.
    ///
    /// - Parameter text: Artifact-controlled text intended for a terminal.
    /// - Returns: Text that cannot contain terminal control sequences.
    public func sanitize(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: isTerminalControl) else { return text }
        var sanitized = ""
        sanitized.reserveCapacity(text.utf8.count)
        for scalar in text.unicodeScalars {
            sanitized.unicodeScalars.append(
                isTerminalControl(scalar) ? "\u{FFFD}" : scalar
            )
        }
        return sanitized
    }

    private func isTerminalControl(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value <= 0x1F || (0x7F...0x9F).contains(scalar.value)
    }
}
