/// Text represented by the render-grid replay contract. Control scalars are
/// cells in some captured output, but must never become replay instructions.
/// Encoding and visual verification share this projection so a safely painted
/// space cannot be rejected as a corrupt replay of its source control cell.
enum MobileTerminalRenderGridText {
    static func replayScalar(_ scalar: UnicodeScalar) -> UnicodeScalar {
        switch scalar.value {
        case 0x20...0x7E, 0xA0...0x10FFFF:
            return scalar
        default:
            return " "
        }
    }

    static func replayText(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: { replayScalar($0) != $0 }) else {
            return text
        }
        return String(String.UnicodeScalarView(text.unicodeScalars.map(replayScalar)))
    }
}
