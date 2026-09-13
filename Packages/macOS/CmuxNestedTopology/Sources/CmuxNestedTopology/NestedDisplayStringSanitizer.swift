import Foundation

/// Sanitizes untrusted nested-provider / proposal strings before publication.
///
/// Strips ASCII control characters (including DEL), truncates to a UTF-8 byte
/// bound, and never treats the result as a path/URL to open automatically.
public enum NestedDisplayStringSanitizer: Sendable {
    /// Default maximum UTF-8 byte length for sanitized display strings.
    public static let defaultMaxUTF8ByteCount = 512

    /// Returns a sanitized copy of `value`.
    ///
    /// - Parameters:
    ///   - value: Untrusted input.
    ///   - maxUTF8ByteCount: Maximum UTF-8 bytes retained after sanitization.
    /// - Returns: Control-character-free, truncated string (may be empty).
    public static func sanitize(
        _ value: String,
        maxUTF8ByteCount: Int = defaultMaxUTF8ByteCount
    ) -> String {
        precondition(maxUTF8ByteCount >= 0)
        // Bound materialization to the output budget; never retain the full input.
        var scalars: [Unicode.Scalar] = []
        scalars.reserveCapacity(min(value.unicodeScalars.count, maxUTF8ByteCount))
        var byteCount = 0
        for scalar in value.unicodeScalars {
            if scalar.value < 0x20 || scalar.value == 0x7F {
                continue
            }
            let piece = String(scalar)
            let pieceBytes = piece.utf8.count
            if byteCount + pieceBytes > maxUTF8ByteCount {
                break
            }
            scalars.append(scalar)
            byteCount += pieceBytes
        }
        return String(String.UnicodeScalarView(scalars))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
