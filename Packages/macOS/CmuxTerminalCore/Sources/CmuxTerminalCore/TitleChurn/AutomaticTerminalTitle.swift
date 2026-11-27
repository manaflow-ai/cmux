/// A bounded, single-line representation of terminal-generated title metadata.
///
/// Use this for OSC/process titles, never for explicit custom names. Short
/// printable titles retain their exact spelling. Line/tab controls become
/// spaces; other C0/C1 controls and bidi embedding/override/isolate controls
/// reject the update. Directional marks, joiners and variation selectors remain
/// available to ordinary multilingual titles and emoji.
public struct AutomaticTerminalTitle: Sendable {
    /// Maximum Unicode scalars, including an ellipsis when truncation is needed.
    ///
    /// 256 scalars allow substantially more than a visible tab label while
    /// bounding storage to at most 1,024 UTF-8 bytes. Truncation retains only
    /// a Unicode scalar boundary, so the result is always valid Swift text.
    public static let maximumScalars = 256

    /// The admitted title, ready for comparison, publication and persistence.
    public let value: String

    /// Admits a title using bounded scalar inspection and allocation.
    ///
    /// - Parameter rawTitle: Terminal-generated text, including legacy saved titles.
    /// - Returns: `nil` if the inspected prefix contains unsafe controls.
    public init?(_ rawTitle: String) {
        var prefix = String()
        var changed = false
        var scalarCount = 0
        // Inspect one scalar past the limit. This keeps both scanning and
        // allocation bounded while preserving valid Unicode scalar boundaries.
        for scalar in rawTitle.unicodeScalars.prefix(Self.maximumScalars + 1) {
            switch scalar.value {
            case 0x09...0x0D, 0x85, 0x2028, 0x2029:
                prefix.append(" ")
                changed = true
            case 0x00...0x1F, 0x7F...0x9F, 0x202A...0x202E, 0x2066...0x2069:
                return nil
            default:
                prefix.unicodeScalars.append(scalar)
            }
            scalarCount += 1
        }
        guard scalarCount > Self.maximumScalars else {
            value = changed ? prefix : rawTitle
            return
        }

        let retainedPrefix = prefix.unicodeScalars.prefix(Self.maximumScalars - 1)
        value = String(retainedPrefix) + "…"
    }
}
