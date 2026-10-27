import AppKit

/// cmux: the compose field's send button follows the field and the draft (ComposeSendSlot).
extension ChatController {
    /// Places the button on the field's bottom-right and shows it while the field has text or an
    /// attachment. `animated`: the waveform-to-button spring (never under Reduce Motion, never
    /// off screen).
    func placeSendButton(animated: Bool) {
        guard let demo else { return }
        let compose = demo.compose
        let slot = ComposeSendSlot(field: compose.fieldRect, text: compose.text, attachments: compose.attachmentCount)
        let button = host.sendButton
        // A layer move; the controls view's cursor, tool tip and hover rects follow (ComposeChromeView).
        button.frame = slot.frame
        button.setLight(Fixture.lightAppearance)
        let animate = animated && host.composeChrome.window != nil && !MessagesLabHomeView.reducesMotion
        // cmux: while dictating the finish and mic buttons stand there instead.
        button.set(shown: slot.shown && !voice.isActive, enabled: slot.enabled, animated: animate)
        placeVoiceControls()
    }
}
