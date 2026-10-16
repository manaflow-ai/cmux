import Foundation

/// Makes invisible or direction-changing characters visible in approval text.
///
/// The annotation is display-only: callers keep the original string for execution. Each
/// hidden scalar is replaced by a visible `⟨U+XXXX⟩` marker so bidi overrides and isolates,
/// zero-width characters, other Unicode format (Cf) controls, stray C0/C1 controls, and
/// line or paragraph separators cannot disguise what will run as root.
struct SudoInvisibleTextAnnotator: Sendable {
    struct Annotation: Sendable, Equatable {
        let display: String
        let hiddenCharacterCount: Int

        var containsHiddenCharacters: Bool { hiddenCharacterCount > 0 }
    }

    func annotate(_ text: String) -> Annotation {
        var display = String.UnicodeScalarView()
        var hiddenCount = 0
        for scalar in text.unicodeScalars {
            if Self.isHidden(scalar) {
                hiddenCount += 1
                display.append(contentsOf: Self.marker(for: scalar).unicodeScalars)
            } else {
                display.append(scalar)
            }
        }
        return Annotation(display: String(display), hiddenCharacterCount: hiddenCount)
    }

    static func isHidden(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09, 0x0A:
            // Tab and newline are the visible layout of a script.
            return false
        case 0x00...0x1F, 0x7F...0x9F:
            return true
        case 0x115F, 0x1160, 0x3164, 0xFFA0:
            // Hangul fillers render as blank glyphs.
            return true
        case 0x034F, 0x180B...0x180F, 0xFE00...0xFE0F, 0xE0100...0xE01EF:
            // Grapheme joiner and variation selectors are invisible modifiers.
            return true
        default:
            break
        }
        switch scalar.properties.generalCategory {
        case .format, .lineSeparator, .paragraphSeparator:
            return true
        default:
            return false
        }
    }

    static func marker(for scalar: Unicode.Scalar) -> String {
        "⟨U+" + String(format: "%04X", scalar.value) + "⟩"
    }
}
