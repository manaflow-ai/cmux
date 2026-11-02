import AppKit

/// cmux: Home's stop control. While the Chief works (`isWorking`), the round
/// button beside the compose field is a stop button, and Esc and Cmd-. in
/// the field (AppKit's `cancelOperation:`) stop it too; all three call the
/// host's one stop action (`onStop`). Option-click on the stop button is
/// the host's Stop all agents (`onStopAll`). Otherwise the button is the
/// emoji button and those keys do what they did.
extension ChatController {
    func roundButtonClicked(option: Bool = NSApp.currentEvent?.modifierFlags.contains(.option) ?? false) {
        guard isWorking else {
            if continueAvailable { onContinue?() } else { showEmojiPicker() }
            return
        }
        if option, let onStopAll { onStopAll() } else { onStop?() }
    }

    func updateStopButton() {
        let button = host.fieldChrome.emoji
        let label = isWorking ? NativeStrings.stop : (continueAvailable ? CmuxStrings.continueTurn : NativeStrings.emoji)
        button.image = isWorking
            ? NSImage(systemSymbolName: "stop.fill", accessibilityDescription: label)?.withSymbolConfiguration(FieldChrome.glyphConfig)
            : (continueAvailable
                ? NSImage(systemSymbolName: "play.fill", accessibilityDescription: label)?.withSymbolConfiguration(FieldChrome.glyphConfig)
                : FieldChrome.emojiGlyph(tinted: false))
        button.image?.accessibilityDescription = label
        button.setAccessibilityLabel(label)
        button.toolTip = isWorking ? stopToolTip ?? label : label
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if handlesHistoryCommand(commandSelector, in: textView) { return true }
        if handlesLineEdgeCommand(commandSelector, in: textView) { return true }
        guard commandSelector == #selector(NSResponder.cancelOperation(_:)), isWorking, picker == nil else { return false }
        onStop?()
        return true
    }
}
