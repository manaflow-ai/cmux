import AppKit

/// cmux: Home's stop control. While the Chief works (`isWorking`), the round
/// button beside the compose field is a stop button, and Esc and Cmd-. in
/// the field (AppKit's `cancelOperation:`) stop it too; all three call the
/// host's one stop action (`onStop`). Otherwise the button is the emoji
/// button and those keys do what they did.
extension ChatController {
    func roundButtonClicked() {
        if isWorking { onStop?() } else { showEmojiPicker() }
    }

    func updateStopButton() {
        let button = host.fieldChrome.emoji
        let label = isWorking ? NativeStrings.stop : NativeStrings.emoji
        button.image = isWorking
            ? NSImage(systemSymbolName: "stop.fill", accessibilityDescription: label)?.withSymbolConfiguration(FieldChrome.glyphConfig)
            : FieldChrome.emojiGlyph(tinted: false)
        button.image?.accessibilityDescription = label
        button.setAccessibilityLabel(label)
        button.toolTip = label
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.cancelOperation(_:)), isWorking, picker == nil else { return false }
        onStop?()
        return true
    }
}
