public import AppKit
import Carbon.HIToolbox
import CmuxNextInput
import CmuxNextWakeups
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
    public override func keyDown(with event: NSEvent) { // perf-hot: 1ms terminal-key (every key typed into a terminal)
        if TypingLatencyProbe.isEnabled { TypingLatencyProbe.shared.keyReachedTerminal(bridgeObject.typingSurface, display: FrameScheduler.appDisplays.display(of: window)) }
        if TerminalClipboardRequests.isPasteChord(event), !clipboardRequests.userPasteInProgress {
            return clipboardRequests.asUserPaste { keyDown(with: event) }
        }
        guard let surface else {
            noteKeyWithoutSurface()
            interpret(event, as: event)
            return
        }
        // Copy mode takes every key except Command chords before Ghostty or
        // an input method sees it.
        if copyMode.handleKeyDown(event) {
            noteKeyTaken()
            return
        }
        // The key goes to the terminal: its echo's frame is awaited from here, and Ghostty's ticks run as input until it.
        lane?.echoStage?.keyDown()
        GhosttyRuntime.shared.noteTerminalKey()

        // Ghostty decides which modifiers take part in text translation (for
        // example `macos-option-as-alt`). Rebuild the event only when that
        // changes the flags: reusing the original event object is required
        // for some input methods (Korean) to keep their state.
        // SAFETY: the view's live surface (TerminalSurfaceView.surface).
        let translationGhosttyMods = unsafe ghostty_surface_key_translation_mods(surface, GhosttyInput.mods(event.modifierFlags))
        let translationEvent = GhosttyInput.translationEvent(for: event, translationMods: translationGhosttyMods)

        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }

        let hadMarkedText = markedText.length > 0
        // A key that switches the input source (for example Ctrl-Space) must
        // not also reach the terminal. Only a system switch key, or a chord
        // while an input method is selected, compares the source (two Text
        // Input Sources reads); Ctrl-C under a keyboard layout reads none.
        let inputSources = GhosttyRuntime.shared.inputSources
        let mayChangeInputSource = !hadMarkedText && inputSources.mayChangeSource(keyCode: event.keyCode, flags: event.modifierFlags)
        let inputSourceBefore = mayChangeInputSource ? inputSources.currentSourceID() : nil
        lastPerformKeyEventTimestamp = nil

        interpret(event, as: translationEvent)

        if mayChangeInputSource, inputSources.sourceChanged(since: inputSourceBefore) {
            return
        }

        syncPreedit(clearIfNeeded: hadMarkedText)
        if hadMarkedText || markedText.length > 0 { noteKeyTaken() }

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
        // Ghostty looks for a link under a resting pointer only on a move to another cell (and, in
        // a program that has the mouse, not on a key): a modifier change looks again, after the key.
        linkPointer.modifiersChanged(event.modifierFlags)
    }

    /// Key equivalents reach the view before the main menu
    /// (`TerminalKeyEquivalent`).
    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard TerminalClipboardRequests.isPasteChord(event) else { return TerminalKeyEquivalent(view: self).perform(event) }
        return clipboardRequests.asUserPaste { TerminalKeyEquivalent(view: self).perform(event) }
    }

    /// Swallows unhandled selectors so AppKit does not beep, and re-sends a
    /// Command/Control chord that `performKeyEquivalent` passed on.
    public override func doCommand(by selector: Selector) {
        guard let previous = lastPerformKeyEventTimestamp,
              let key = interpretingKeyDown,
              previous == key.timestamp else { return }
        resendKey(key)
    }

    /// Runs `translated` through the input methods for the key down `event`, which is
    /// ``interpretingKeyDown`` meanwhile (upstream reads AppKit's current event, which a key the App
    /// routes itself is not). The call is the key's text input stage (``TextInputStage``).
    func interpret(_ event: NSEvent, as translated: NSEvent) {
        let outer = interpretingKeyDown
        interpretingKeyDown = event
        defer { interpretingKeyDown = outer }
        guard let textInputStage else { return runInputMethods(translated) }
        textInputStage.interpreting(event) { runInputMethods(translated) }
    }

    private func runInputMethods(_ translated: NSEvent) {
        if let inputMethod { inputMethod(self, translated) } else { interpretKeyEvents([translated]) }
    }

    // MARK: Sending

    /// The key-down being dispatched changed what this terminal shows: echo prediction takes its bytes, and the app's
    /// delegate tells the scheduler a frame is expected (``TerminalSessionDelegate/terminalSessionTookKey(_:)``).
    func noteKeyTaken() {
        bridgeObject.input.predictions.keyTaken(by: self)
        if let session { session.delegate?.terminalSessionTookKey(session) }
    }

    /// Sends one key transition to Ghostty; a press or repeat Ghostty took is ``noteKeyTaken()``.
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
        let took: Bool
        if let text, !text.isEmpty, !GhosttyInput.startsWithControlCharacter(text) {
            // SAFETY: the view's live surface (TerminalSurfaceView.surface); the key's text is the
            // NUL-terminated copy withCString lends for the closure, and Ghostty does not keep it.
            took = unsafe text.withCString { pointer in
                // SAFETY: as above.
                unsafe keyEvent.text = pointer
                // SAFETY: as above.
                return clipboardRequests.asUserClipboardWrite { unsafe ghostty_surface_key(surface, keyEvent) }
            }
        } else {
            // SAFETY: the view's live surface (TerminalSurfaceView.surface); the key has no text.
            took = clipboardRequests.asUserClipboardWrite { unsafe ghostty_surface_key(surface, keyEvent) }
        }
        if took, action != GHOSTTY_ACTION_RELEASE { TypingLatencyProbe.shared.terminalTookKey(); noteKeyTaken() }
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
        // SAFETY: the view's live surface (TerminalSurfaceView.surface); the key's text is the
        // NUL-terminated copy withCString lends for the closure, and Ghostty does not keep it.
        let took = unsafe text.withCString { pointer in
            // SAFETY: as above.
            unsafe keyEvent.text = pointer
            // SAFETY: as above.
            return clipboardRequests.asUserClipboardWrite { unsafe ghostty_surface_key(surface, keyEvent) }
        }
        if took { TypingLatencyProbe.shared.terminalTookKey(); noteKeyTaken() }
    }

    func syncPreedit(clearIfNeeded: Bool = true) {
        guard let surface else { return }
        if markedText.length > 0 {
            let text = markedText.string
            // SAFETY: the view's live surface (TerminalSurfaceView.surface); Swift passes a
            // NUL-terminated copy of `text` for the call, its length without the NUL.
            unsafe ghostty_surface_preedit(surface, text, UInt(text.utf8.count))
        } else if clearIfNeeded {
            // SAFETY: the view's live surface; a null preedit of length 0 clears it.
            unsafe ghostty_surface_preedit(surface, nil, 0)
        }
    }
}
