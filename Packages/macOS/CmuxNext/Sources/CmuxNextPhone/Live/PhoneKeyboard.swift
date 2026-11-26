/// USB HID keyboard usages for a US layout: what typed text and Mac key
/// codes become on the simulator's hardware keyboard (`cmux-phone-core`'s
/// ops `key_strokes` and `mac_key_usage`).
struct PhoneKeyboard {
    private struct Stroke: Decodable {
        let usage: UInt32
        let shift: Bool
    }

    /// The key strokes that type `text`, or nil when a character has no US
    /// key (the backend then pastes the text instead).
    func strokes(for text: String) -> [PhoneKeyStroke]? {
        guard let strokes = try? PhoneRules.decode([Stroke]?.self, "strokes", "key_strokes", ["text": text], what: "the key strokes")
        else { return nil }
        return strokes?.map { PhoneKeyStroke(usage: $0.usage, shift: $0.shift) }
    }

    /// The HID usage for a Mac virtual key code (`NSEvent.keyCode`); nil for
    /// keys the simulator has no use for.
    func usage(forMacKeyCode code: UInt16) -> UInt32? {
        (try? PhoneRules.decode(UInt32?.self, "usage", "mac_key_usage", ["code": code], what: "the key usage")) ?? nil
    }
}
