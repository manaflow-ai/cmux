import Foundation

/// Short text a client puts in front of a tab's title, such as an emoji that
/// identifies the account or environment a terminal belongs to.
///
/// Unlike a custom tab name, a badge does not replace the live title: the tab
/// shows `<badge> <title>` and keeps following the terminal's title. Admitted
/// text is trimmed, is a single line, has at least one visible character, has
/// no control or bidi formatting characters, and is at most
/// ``maximumCharacters`` grapheme clusters and ``maximumScalars`` Unicode
/// scalars. The scalar cap bounds the size, since one grapheme cluster can
/// carry any number of combining marks; it still fits ``maximumCharacters``
/// multi-scalar emoji such as flags and ZWJ families.
///
/// ```swift
/// PanelBadgeText("🦀")?.titled("cargo build")  // "🦀 cargo build"
/// PanelBadgeText("a\nb")                         // nil
/// ```
public struct PanelBadgeText: Sendable, Hashable {
    /// Maximum grapheme clusters (user-perceived characters) in a badge.
    public static let maximumCharacters = 16

    /// Maximum Unicode scalars in a badge.
    public static let maximumScalars = 128

    /// The admitted badge text.
    public let value: String

    /// Admits badge text.
    ///
    /// Only a bounded prefix of `rawText` is inspected, so an oversized input
    /// is rejected without walking all of it.
    ///
    /// - Parameter rawText: Client-supplied text.
    /// - Returns: `nil` if the trimmed text is empty or only invisible
    ///   characters, exceeds ``maximumCharacters`` or ``maximumScalars``, or
    ///   contains line breaks, control characters or bidi
    ///   embedding/override/isolate controls.
    public init?(_ rawText: String) {
        // Whitespace on either side is trimmed, so allow for it in the bound.
        let inspectionLimit = Self.maximumScalars * 4
        let scalars = rawText.unicodeScalars
        guard scalars.prefix(inspectionLimit + 1).count <= inspectionLimit else { return nil }
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.unicodeScalars.count <= Self.maximumScalars,
              !trimmed.isEmpty,
              trimmed.count <= Self.maximumCharacters else { return nil }
        var hasVisibleScalar = false
        for scalar in trimmed.unicodeScalars {
            switch scalar.value {
            case 0x00...0x1F, 0x7F...0x9F, 0x2028, 0x2029, 0x202A...0x202E, 0x2066...0x2069:
                return nil
            default:
                if !scalar.properties.isWhitespace, !scalar.properties.isDefaultIgnorableCodePoint {
                    hasVisibleScalar = true
                }
            }
        }
        guard hasVisibleScalar else { return nil }
        value = trimmed
    }

    /// Puts the badge in front of a title: `<badge> <title>`.
    ///
    /// - Parameter title: The tab's title without a badge.
    /// - Returns: The badged title.
    public func titled(_ title: String) -> String {
        "\(value) \(title)"
    }
}
