import AppKit

/// cmux: Home's stop control. While the Chief works (`isWorking`), the round
/// button beside the compose field is a stop button, and Esc and Cmd-. in
/// the field (AppKit's `cancelOperation:`) stop it too; all three call the
/// host's one stop action (`onStop`). Otherwise the button is the emoji
/// button and those keys do what they did.
extension ChatController {
    func roundButtonClicked() {
        // cmux-classic: while an approval card waits the button is a disabled send (the card is the action).
        if isWorking && isWaitingForApproval { return }
        if isWorking { onStop?() } else { showEmojiPicker() }
    }

    /// cmux-classic: while an approval card waits there is no Stop: the card is the one action and
    /// "Waiting for you" the one status, so the button is a disabled send whose tooltip says what
    /// to do ("Allow or deny above to continue"). Esc in the field denies the card.
    func updateStopButton() {
        let button = host.fieldChrome.emoji
        let waiting = isWorking && isWaitingForApproval
        let label = waiting ? CmuxStrings.approvalPlaceholder : isWorking ? NativeStrings.stop : NativeStrings.emoji
        if waiting {
            let dim = NSImage.SymbolConfiguration(paletteColors: [Fixture.secondaryText.withAlphaComponent(0.45)])
            button.image = NSImage(systemSymbolName: "arrow.up.circle.fill", accessibilityDescription: label)?
                .withSymbolConfiguration(FieldChrome.glyphConfig.applying(dim))
        } else {
            button.image = isWorking
                ? NSImage(systemSymbolName: "stop.fill", accessibilityDescription: label)?.withSymbolConfiguration(FieldChrome.glyphConfig)
                : FieldChrome.emojiGlyph(tinted: false)
        }
        button.isEnabled = !waiting
        button.image?.accessibilityDescription = label
        button.setAccessibilityLabel(label)
        button.setAccessibilityHelp(nil)
        button.toolTip = label
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.cancelOperation(_:)), isWorking, picker == nil else { return false }
        // While a card waits Esc denies it, as on the card itself (no Stop then).
        if isWaitingForApproval { return answerPendingApproval(prominent: false) }
        onStop?()
        return true
    }
}
