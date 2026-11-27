internal import Foundation

/// Converts an optional recording label into one safe filename component.
///
/// Same rules as the screenshot label: the label reaches the filesystem, and a
/// caller that names a recording after a branch or a test can put anything in
/// it, including a path separator.
public struct WindowRecordingLabel: Sendable, Equatable {
    private static let maximumUTF8ByteCount = 80

    public let value: String

    /// - Parameters:
    ///   - input: the caller's label, which may be empty or unusable.
    ///   - fallback: what a label that sanitizes away entirely becomes, so a
    ///     still is not filed under the word "recording". An empty input still
    ///     gives an empty label: the naming helper leaves that component out.
    public init(_ input: String, fallback: String = "recording") {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            value = ""
            return
        }

        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "-_.")
        )
        let scalars = trimmed.unicodeScalars.map {
            allowed.contains($0) ? Character($0) : "-"
        }
        let cleaned = String(scalars)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-_."))
        guard !cleaned.isEmpty else {
            value = fallback
            return
        }

        var byteCount = 0
        value = String(cleaned.prefix { character in
            let characterByteCount = String(character).utf8.count
            guard byteCount + characterByteCount <= Self.maximumUTF8ByteCount else {
                return false
            }
            byteCount += characterByteCount
            return true
        })
    }
}
