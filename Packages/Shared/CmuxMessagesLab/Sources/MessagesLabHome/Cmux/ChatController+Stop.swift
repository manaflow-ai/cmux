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

    /// While an approval card waits, Stop stays (it denies the request) but steps back: a smaller
    /// square, so the card's tinted Allow reads as the action, and its help says what it does.
    func updateStopButton() {
        let button = host.fieldChrome.emoji
        let label = isWorking ? NativeStrings.stop : NativeStrings.emoji
        let quiet = isWorking && isWaitingForApproval
        let config = quiet ? NSImage.SymbolConfiguration(pointSize: 11, weight: .medium) : FieldChrome.glyphConfig
        button.image = isWorking
            ? NSImage(systemSymbolName: "stop.fill", accessibilityDescription: label)?.withSymbolConfiguration(config)
            : FieldChrome.emojiGlyph(tinted: false)
        button.image?.accessibilityDescription = label
        button.setAccessibilityLabel(label)
        button.setAccessibilityHelp(quiet ? CmuxStrings.approvalStopHelp : nil)
        button.toolTip = quiet ? CmuxStrings.approvalStopHelp : label
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.cancelOperation(_:)), isWorking, picker == nil else { return false }
        onStop?()
        return true
    }
}
