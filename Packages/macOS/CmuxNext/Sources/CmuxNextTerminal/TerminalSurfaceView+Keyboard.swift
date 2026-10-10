public import AppKit
import Carbon.HIToolbox
import GhosttyNextKit

// Keyboard and IME input.
//
// keyDown runs the event through `interpretKeyEvents` so input methods
// (Japanese, Korean, Chinese, dead keys, emoji) see it first. Committed text
// accumulates in `keyTextAccumulator` and goes to `ghostty_surface_key` with
// the physical key attached, marked text goes to `ghostty_surface_preedit`,
// and the IME candidate window is positioned from `ghostty_surface_ime_point`
// (ghostty.h:1571, :1586, :1656).
extension TerminalSurfaceView {
    public override func keyDown(with event: NSEvent) {
        guard let surface else {
            interpretKeyEvents([event])
            return
        }
        // Copy mode takes every key except Command chords before Ghostty or
        // an input method sees it.
        if copyMode.handleKeyDown(event) { return }

        // Ghostty decides which modifiers take part in text translation (for
        // example `macos-option-as-alt`). Rebuild the event only when that
        // changes the flags: reusing the original event object is required
        // for some input methods (Korean) to keep their state.
        let translationGhosttyMods = ghostty_surface_key_translation_mods(surface, GhosttyInput.mods(event.modifierFlags))
        let translationEvent = GhosttyInput.translationEvent(for: event, translationMods: translationGhosttyMods)

        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }

        let hadMarkedText = markedText.length > 0
        // A key that switches the input source (for example Ctrl-Space) must
        // not also reach the terminal.
        let inputSourceBefore = hadMarkedText ? nil : GhosttyInput.currentInputSourceID()
        lastPerformKeyEventTimestamp = nil

        interpretKeyEvents([translationEvent])

        if !hadMarkedText, inputSourceBefore != GhosttyInput.currentInputSourceID() {
            return
        }

        syncPreedit(clearIfNeeded: hadMarkedText)

        // Composing covers the key that ended a composition too: Backspace
        // that cancels Japanese preedit must not also delete a character.
        let composing = markedText.length > 0 || hadMarkedText
        let committed = keyTextAccumulator ?? []

        if hadMarkedText, !committed.isEmpty {
            for text in committed where !GhosttyInput.isComposingControl(text, composing: composing) {
                sendCommittedText(text, action: action)
            }
            if GhosttyInput.shouldReplayAfterCommit(event) {
                sendKey(action, event: event, translationEvent: translationEvent)
            }
            return
        }

        if !committed.isEmpty {
            for text in committed where !GhosttyInput.isComposingControl(text, composing: composing) {
                sendKey(action, event: event, translationEvent: translationEvent, text: text)
            }
            return
        }

        if GhosttyInput.isComposingControl(event.characters, composing: composing) {
            return
        }
        sendKey(
            action,
            event: event,
            translationEvent: translationEvent,
            text: GhosttyInput.keyText(for: translationEvent),
            composing: composing
        )
    }

    public override func keyUp(with event: NSEvent) {
        if copyMode.handleKeyUp(event) { return }
        sendKey(GHOSTTY_ACTION_RELEASE, event: event)
    }

    public override func flagsChanged(with event: NSEvent) {
        guard !hasMarkedText(), let action = GhosttyInput.modifierAction(for: event) else { return }
        sendKey(action, event: event)
    }

    /// Key equivalents reach the view before the main menu
    /// (`TerminalKeyEquivalent`).
    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        TerminalKeyEquivalent(view: self).perform(event)
    }

    /// Swallows unhandled selectors so AppKit does not beep, and re-sends a
    /// Command/Control chord that `performKeyEquivalent` passed on.
    public override func doCommand(by selector: Selector) {
        guard let previous = lastPerformKeyEventTimestamp,
              let current = NSApp.currentEvent,
              previous == current.timestamp else { return }
        NSApp.sendEvent(current)
    }

    // MARK: Sending

    func sendKey(
        _ action: ghostty_input_action_e,
        event: NSEvent,
        translationEvent: NSEvent? = nil,
        text: String? = nil,
        composing: Bool = false
    ) {
        guard let surface else { return }
        var keyEvent = GhosttyInput.keyEvent(event, action: action, translationMods: translationEvent?.modifierFlags)
        keyEvent.composing = composing
        // Ghostty encodes control characters from keycode + mods itself so
        // the Kitty keyboard protocol still sees the physical key.
        if let text, !text.isEmpty, !GhosttyInput.startsWithControlCharacter(text) {
            text.withCString { pointer in
                keyEvent.text = pointer
                _ = ghostty_surface_key(surface, keyEvent)
            }
        } else {
            _ = ghostty_surface_key(surface, keyEvent)
        }
    }

    /// Text an input method committed while handling a key that belongs to
    /// the IME. Sent as a key event without a physical key so programs can
    /// still interpret it.
    func sendCommittedText(_ text: String, action: ghostty_input_action_e) {
        guard let surface else { return }
        var keyEvent = ghostty_input_key_s()
        keyEvent.action = action
        keyEvent.mods = GHOSTTY_MODS_NONE
        keyEvent.consumed_mods = GHOSTTY_MODS_NONE
        text.withCString { pointer in
            keyEvent.text = pointer
            _ = ghostty_surface_key(surface, keyEvent)
        }
    }

    func syncPreedit(clearIfNeeded: Bool = true) {
        guard let surface else { return }
        if markedText.length > 0 {
            let text = markedText.string
            text.withCString { pointer in
                ghostty_surface_preedit(surface, pointer, UInt(text.utf8.count))
            }
        } else if clearIfNeeded {
            ghostty_surface_preedit(surface, nil, 0)
        }
    }
}
