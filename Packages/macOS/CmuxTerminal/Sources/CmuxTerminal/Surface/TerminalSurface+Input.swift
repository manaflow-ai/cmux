public import Foundation
public import GhosttyKit
public import CmuxTerminalCore
internal import Carbon.HIToolbox
#if DEBUG
internal import CMUXDebugLog
#endif

// MARK: - Socket/API input: send paths, pending queues, parsing

extension TerminalSurface {
    /// Whether closing this surface should ask for confirmation.
    public func needsConfirmClose() -> Bool {
#if DEBUG
        if let needsConfirmCloseOverrideForTesting {
            return needsConfirmCloseOverrideForTesting
        }
#endif
        guard let surface = surface else { return false }
        return ghostty_surface_needs_confirm_quit(surface)
    }

    /// Records a completed runtime clipboard read and notifies observers.
    public func noteClipboardReadCompleted() {
        clipboardReadGeneration += 1
        NotificationCenter.default.post(
            name: .terminalSurfaceDidCompleteClipboardRead,
            object: self
        )
    }

    /// Sends paste-style text to the surface, queueing on a cold surface.
    ///
    /// - Returns: Whether the text was delivered or queued.
    @MainActor
    @discardableResult
    public func sendText(_ text: String) -> Bool {
        guard let data = text.data(using: .utf8), !data.isEmpty else { return true }
        guard surface != nil else {
            guard allowsRuntimeSurfaceCreation() else { return false }
            let queued = enqueuePendingSocketInput(.pasteText(data))
            if queued {
                hibernationRecorder.recordTerminalInput(workspaceId: tabId, panelId: id)
                requestInputDemandSurfaceStartIfNeeded()
            }
            return queued
        }
        guard let liveSurface = liveSurfaceForSocketWrite(reason: "socket.sendText") else {
            return false
        }
        guard !ghostty_surface_process_exited(liveSurface) else { return false }
        hibernationRecorder.recordTerminalInput(workspaceId: tabId, panelId: id)
        writeTextData(data, to: liveSurface)
        return true
    }

    /// Sends raw key text as a single key event.
    ///
    /// - Returns: Whether the runtime handled the key.
    @MainActor
    @discardableResult
    public func sendKeyText(_ text: String) -> Bool {
        guard !text.isEmpty else { return true }
        guard let liveSurface = liveSurfaceForSocketWrite(reason: "socket.sendKeyText") else {
            return false
        }
        guard !ghostty_surface_process_exited(liveSurface) else { return false }

        var keyEvent = ghostty_input_key_s()
        keyEvent.action = GHOSTTY_ACTION_PRESS
        keyEvent.keycode = 0
        keyEvent.mods = GHOSTTY_MODS_NONE
        keyEvent.consumed_mods = GHOSTTY_MODS_NONE
        keyEvent.unshifted_codepoint = 0
        keyEvent.composing = false
        return text.withCString { ptr in
            keyEvent.text = ptr
            return ghostty_surface_key(liveSurface, keyEvent)
        }
    }

    /// Sends a named key (e.g. `"ctrl-c"`, `"enter"`), queueing on a cold
    /// surface.
    @MainActor
    @discardableResult
    public func sendNamedKey(_ keyName: String) -> NamedKeySendResult {
        guard let event = pendingKeyEvent(for: keyName) else { return .unknownKey }
        guard surface != nil else {
            guard allowsRuntimeSurfaceCreation() else { return .surfaceUnavailable }
            guard enqueuePendingSocketInput(.key(event)) else { return .inputQueueFull }
            hibernationRecorder.recordTerminalInput(workspaceId: tabId, panelId: id)
            requestInputDemandSurfaceStartIfNeeded()
            return .queued
        }
        guard let liveSurface = liveSurfaceForSocketWrite(reason: "socket.sendNamedKey") else {
            return .surfaceUnavailable
        }
        guard !ghostty_surface_process_exited(liveSurface) else { return .processExited }
        hibernationRecorder.recordTerminalInput(workspaceId: tabId, panelId: id)
        sendKeyEvent(surface: liveSurface, keycode: event.keycode, mods: event.mods)
        return .sent
    }

    /// Clears the focused terminal's screen while preserving scrollback by sending
    /// Ctrl-L (form-feed) to the running program — exactly as if the user pressed the
    /// key.
    ///
    /// Shells clear the viewport and redraw the prompt while leaving scrollback
    /// intact, and full-screen TUIs (vim, less, …) simply repaint. Because this is
    /// ordinary keyboard input rather than an erase sequence injected through the
    /// PTY-output parser, it never mutates the terminal behind the running program's
    /// back, so it stays safe on the alternate screen. Ghostty's own ^L-at-a-prompt
    /// heuristic scrolls the cleared screen into scrollback when shell prompt markers
    /// are present; unlike `clear_screen` (⌘K), scrollback is never erased.
    ///
    /// - Returns: `true` when the keystroke was delivered or queued for the focused
    ///   terminal, `false` when no live surface could accept it.
    @MainActor
    @discardableResult
    public func clearScreenKeepingScrollback() -> Bool {
        return sendNamedKey("ctrl-l").accepted
    }

    /// The visible viewport text, or nil without a live surface.
    @MainActor
    public func visibleText() -> String? {
        guard let surface = liveSurfaceForGhosttyAccess(reason: "visibleText") else { return nil }
        return Self.readText(surface: surface, pointTag: GHOSTTY_POINT_VIEWPORT)
    }

    /// Send text with control characters (Return, Tab, etc.) delivered as key
    /// events so the shell processes them, while complete terminal control
    /// sequences are routed through Ghostty's PTY-output parser. Cold surfaces
    /// queue the same ordered events and flush them after runtime creation.
    @MainActor
    @discardableResult
    public func sendInput(_ text: String) -> Bool {
        return sendInputResult(text).accepted
    }

    /// ``sendInput(_:)`` with a structured result.
    @MainActor
    @discardableResult
    public func sendInputResult(_ text: String) -> InputSendResult {
        guard !text.isEmpty else { return .sent }
        guard surface != nil else {
            guard allowsRuntimeSurfaceCreation() else { return .surfaceUnavailable }
            let queued = enqueuePendingSocketInput(text)
            if queued {
                hibernationRecorder.recordTerminalInput(workspaceId: tabId, panelId: id)
                requestInputDemandSurfaceStartIfNeeded()
            }
            return queued ? .queued : .inputQueueFull
        }
        guard let liveSurface = liveSurfaceForSocketWrite(reason: "socket.sendInput") else {
            return .surfaceUnavailable
        }
        guard !ghostty_surface_process_exited(liveSurface) else { return .processExited }
        hibernationRecorder.recordTerminalInput(workspaceId: tabId, panelId: id)
        sendInput(text, to: liveSurface)
        return .sent
    }

    @MainActor
    private func sendInput(_ text: String, to surface: ghostty_surface_t) {
        for event in Self.parsedSocketInputEvents(for: text) {
            switch event {
            case .rawBytes(let data):
                writeInputTextData(data, to: surface)
            case .terminalBytes(let data):
                writeProcessOutputData(data, to: surface)
            case .key(let event):
                sendKeyEvent(surface: surface, keycode: event.keycode, mods: event.mods)
            }
        }
    }

    @MainActor
    private func enqueuePendingSocketInput(_ text: String) -> Bool {
        let inputs = Self.parsedSocketInputEvents(for: text).compactMap { event -> PendingSocketInput? in
            switch event {
            case .rawBytes(let data):
                return data.isEmpty ? nil : .inputText(data)
            case .terminalBytes(let data):
                return data.isEmpty ? nil : .processOutput(data)
            case .key(let event):
                return .key(event)
            }
        }
        return enqueuePendingSocketInputs(inputs)
    }

    /// Splits socket text into ordered raw-byte, terminal-byte, and key
    /// events (the socket input grammar).
    public static func parsedSocketInputEvents(for text: String) -> [ParsedSocketInput] {
        guard !text.isEmpty else { return [] }

        var events: [ParsedSocketInput] = []
        events.reserveCapacity(8)
        var bufferedText = ""
        bufferedText.reserveCapacity(text.count)
        var previousWasCR = false
        let scalars = Array(text.unicodeScalars)

        func flushBufferedText() {
            guard !bufferedText.isEmpty else { return }
            for chunk in committedTextInputChunks(from: bufferedText) {
                events.append(.rawBytes(chunk))
            }
            bufferedText.removeAll(keepingCapacity: true)
        }

        func appendKey(_ keycode: UInt32, mods: ghostty_input_mods_e = GHOSTTY_MODS_NONE, label: String) {
            events.append(.key(PendingKeyEvent(
                keycode: keycode,
                mods: mods,
                label: label
            )))
        }

        func appendRawReturn() {
            events.append(.rawBytes(Data([0x0D])))
        }

        func appendTerminalBytes(length: Int, from start: Int) {
            guard length > 0 else { return }
            var sequence = ""
            for offset in start..<(start + length) {
                sequence.unicodeScalars.append(scalars[offset])
            }
            guard let data = sequence.data(using: .utf8), !data.isEmpty else { return }
            events.append(.terminalBytes(data))
        }

        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            switch scalar.value {
            case 0x0A:
                if !previousWasCR {
                    flushBufferedText()
                    appendRawReturn()
                }
                previousWasCR = false
                index += 1
            case 0x0D:
                flushBufferedText()
                appendRawReturn()
                previousWasCR = true
                index += 1
            case 0x09:
                flushBufferedText()
                appendKey(UInt32(kVK_Tab), label: "tab")
                previousWasCR = false
                index += 1
            case 0x1B:
                // A bare ESC is the Escape key. But a full CSI/SS3 navigation
                // sequence arriving as raw input (the iOS on-screen arrows send
                // ESC[B, etc.) must stay one key press, or the terminal receives
                // Escape followed by literal "[B". Re-issue recognized sequences
                // as key events so libghostty encodes them for the surface's
                // current cursor-key mode, exactly like a hardware arrow press.
                if let nav = navigationEscapeKey(scalars, from: index) {
                    flushBufferedText()
                    appendKey(nav.keycode, mods: nav.mods, label: nav.label)
                    index += nav.length
                } else if let length = terminalControlSequenceLength(scalars, from: index) {
                    // A sequence the *emulator* must consume — a DSR query
                    // (`ESC[6n` / `ESC[5n`) or an OSC/DCS/PM/APC string — is
                    // injected into the terminal parser as process output, not the
                    // PTY input stream, so Ghostty can update state or answer (a
                    // DSR query makes it emit its own CPR reply). Splitting these
                    // into Escape + literal text is the #5763 cursor-desync bug.
                    // Only this narrow set matches: interactive CSI input (function
                    // keys, kitty-keyboard, mouse, arbitrary `terminal.input`) and
                    // terminal-to-application *responses* (CPR `ESC[…R`, DSR results
                    // `ESC[0n`/`ESC[3n`) fall through to the input path below,
                    // never the display parser, so they reach the foreground
                    // program. Printable text takes the input-text path above, and
                    // pasted/composed blocks use the separate `sendText`
                    // (bracketed-paste) path.
                    flushBufferedText()
                    appendTerminalBytes(length: length, from: index)
                    index += length
                } else {
                    flushBufferedText()
                    appendKey(UInt32(kVK_Escape), label: "escape")
                    index += 1
                }
                previousWasCR = false
            case 0x08, 0x7F:
                flushBufferedText()
                appendKey(UInt32(kVK_Delete), label: "backspace")
                previousWasCR = false
                index += 1
            default:
                bufferedText.unicodeScalars.append(scalar)
                previousWasCR = false
                index += 1
            }
        }
        flushBufferedText()
        return events
    }

    /// Match a CSI (`ESC [ …`) or SS3 (`ESC O …`) cursor/navigation escape
    /// sequence beginning at `start` (which points at the ESC, 0x1B). Returns
    /// the equivalent macOS key code and how many scalars the sequence consumed,
    /// or nil for a bare ESC or an unrecognized sequence (which stays the
    /// Escape key). Only unmodified navigation keys are mapped; the surface
    /// re-encodes them for its current DECCKM cursor-key mode.
    private static func navigationEscapeKey(
        _ scalars: [Unicode.Scalar],
        from start: Int
    ) -> (keycode: UInt32, mods: ghostty_input_mods_e, label: String, length: Int)? {
        guard start + 1 < scalars.count else { return nil }
        let next = scalars[start + 1].value
        // Meta+Backspace: the iOS app sends ESC 0x7F (or ESC 0x08) for
        // option-delete-word. Re-issue as Backspace with the Option modifier so
        // libghostty encodes the meta-backspace for the surface, instead of the
        // bare-ESC path splitting it into Escape + a plain backspace.
        if next == 0x7F || next == 0x08 {
            return (UInt32(kVK_Delete), GHOSTTY_MODS_ALT, "alt-backspace", 2)
        }
        // CSI (ESC[) / SS3 (ESCO) cursor + navigation sequences.
        guard next == 0x5B || next == 0x4F, start + 2 < scalars.count else { return nil }
        let final = scalars[start + 2].value
        switch final {
        case 0x41: return (UInt32(kVK_UpArrow), GHOSTTY_MODS_NONE, "up", 3)        // A
        case 0x42: return (UInt32(kVK_DownArrow), GHOSTTY_MODS_NONE, "down", 3)    // B
        case 0x43: return (UInt32(kVK_RightArrow), GHOSTTY_MODS_NONE, "right", 3)  // C
        case 0x44: return (UInt32(kVK_LeftArrow), GHOSTTY_MODS_NONE, "left", 3)    // D
        case 0x48: return (UInt32(kVK_Home), GHOSTTY_MODS_NONE, "home", 3)         // H
        case 0x46: return (UInt32(kVK_End), GHOSTTY_MODS_NONE, "end", 3)           // F
        default:
            break
        }
        // Shift+Tab (back-tab) arrives as CSI Z (`ESC[Z`). Like the arrows above
        // it is an interactive key, so re-issue it as Shift+Tab and let libghostty
        // encode it for the surface's current keyboard mode — matching a hardware
        // back-tab. Otherwise it falls through to the bare-ESC path (Escape key +
        // literal `[Z`), which a kitty-keyboard surface would encode as a modified
        // Escape and corrupt (the DSR-query matcher does not claim `ESC[Z`: it is
        // not `ESC[5n`/`ESC[6n`). The iOS client emits
        // this for a hardware Shift+Tab and the on-screen ⇧+Tab accessory; it is
        // the socket sibling of the `backtab` named key in `pendingKeyEvent(for:)`.
        if next == 0x5B, final == 0x5A { // Z
            return (UInt32(kVK_Tab), GHOSTTY_MODS_SHIFT, "backTab", 3)
        }
        // CSI tilde sequences: ESC [ N ~
        if next == 0x5B, start + 3 < scalars.count, scalars[start + 3].value == 0x7E {
            switch final {
            case 0x31: return (UInt32(kVK_Home), GHOSTTY_MODS_NONE, "home", 4)               // 1~
            case 0x33: return (UInt32(kVK_ForwardDelete), GHOSTTY_MODS_NONE, "forwardDelete", 4) // 3~
            case 0x34: return (UInt32(kVK_End), GHOSTTY_MODS_NONE, "end", 4)                 // 4~
            case 0x35: return (UInt32(kVK_PageUp), GHOSTTY_MODS_NONE, "pageUp", 4)           // 5~
            case 0x36: return (UInt32(kVK_PageDown), GHOSTTY_MODS_NONE, "pageDown", 4)       // 6~
            default:
                break
            }
        }
        return nil
    }

    private static func committedTextInputChunks(from text: String) -> [Data] {
        guard !text.isEmpty else { return [] }

        var chunks: [Data] = []
        chunks.reserveCapacity(max(1, (text.utf8.count / committedTextInputChunkByteLimit) + 1))
        var chunk = Data()
        chunk.reserveCapacity(committedTextInputChunkByteLimit)

        func flushChunk() {
            guard !chunk.isEmpty else { return }
            chunks.append(chunk)
            chunk.removeAll(keepingCapacity: true)
        }

        for scalar in text.unicodeScalars {
            let scalarBytes = String(scalar).utf8
            if !chunk.isEmpty, chunk.count + scalarBytes.count > committedTextInputChunkByteLimit {
                flushChunk()
            }
            chunk.append(contentsOf: scalarBytes)
        }
        flushChunk()
        return chunks
    }

    // Canonical key text for synthetic key events sent from the mobile/socket
    // input path (see `sendKeyEvent`). The desktop `keyDown` handler fills
    // `ghostty_input_key_s.text` from `charactersIgnoringModifiers`; libghostty
    // needs that text to encode control keys whose byte is otherwise filtered by
    // the raw-text input path. Mobile builds the event from a bare keycode, so we
    // reproduce the same canonical text here, keyed purely off the keycode.
    //
    // Only Backspace/Delete and Tab need this: their physical macOS keys carry
    // the DEL (0x7F) and TAB (0x09) characters in `charactersIgnoringModifiers`.
    // The text is independent of modifiers (Option-Backspace still reports DEL),
    // so this intentionally ignores `mods`. Pure function keys (arrows, Home,
    // End, page navigation) carry no characters and correctly encode from the
    // keycode alone, so they return nil.
    private static func canonicalKeyText(keycode: UInt32) -> String? {
        switch keycode {
        case UInt32(kVK_Delete):
            return "\u{7F}"
        case UInt32(kVK_Tab):
            return "\t"
        default:
            return nil
        }
    }

    func sendKeyEvent(
        surface: ghostty_surface_t,
        keycode: UInt32,
        mods: ghostty_input_mods_e = GHOSTTY_MODS_NONE
    ) {
        var keyEvent = ghostty_input_key_s()
        keyEvent.action = GHOSTTY_ACTION_PRESS
        keyEvent.keycode = keycode
        keyEvent.mods = mods
        keyEvent.consumed_mods = GHOSTTY_MODS_NONE
        keyEvent.composing = false

        let canonicalText = Self.canonicalKeyText(keycode: keycode)
        keyEvent.unshifted_codepoint = canonicalText?.unicodeScalars.first?.value ?? 0

        let handled: Bool
        if let canonicalText {
            // Mirror the desktop `keyDown` path's C-string lifetime: the text
            // pointer must stay valid only for the `ghostty_surface_key` call.
            handled = canonicalText.withCString { ptr in
                keyEvent.text = ptr
                return ghostty_surface_key(surface, keyEvent)
            }
        } else {
            keyEvent.text = nil
            handled = ghostty_surface_key(surface, keyEvent)
        }

#if DEBUG
        logDebugEvent(
            "surface.socket_input.key surface=\(id.uuidString.prefix(8)) " +
            "keycode=\(keycode) mods=\(mods.rawValue) " +
            "codepoint=0x\(String(keyEvent.unshifted_codepoint, radix: 16)) " +
            "handled=\(handled ? 1 : 0)"
        )
#endif
    }

    @MainActor
    private func liveSurfaceForSocketWrite(reason: String) -> ghostty_surface_t? {
        return liveSurfaceForGhosttyAccess(reason: reason)
    }

    func writeTextData(_ data: Data, to surface: ghostty_surface_t) {
        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress?.assumingMemoryBound(to: CChar.self) else { return }
            ghostty_surface_text(surface, baseAddress, UInt(rawBuffer.count))
        }
    }

    func writeInputTextData(_ data: Data, to surface: ghostty_surface_t) {
        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress?.assumingMemoryBound(to: CChar.self) else { return }
            ghostty_surface_text_input(surface, baseAddress, UInt(rawBuffer.count))
        }
    }

    /// Sends bytes through Ghostty's PTY-output parser so OSC commands affect terminal state.
    func writeProcessOutputData(_ data: Data, to surface: ghostty_surface_t) {
        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress?.assumingMemoryBound(to: CChar.self) else { return }
            ghostty_surface_process_output(surface, baseAddress, UInt(rawBuffer.count))
        }
    }

    /// Sets whether a manual-I/O surface should suppress Ghostty's primary
    /// screen reflow on resize. Remote tmux marks TUI/alt-screen panes true and
    /// plain shell panes false.
    @MainActor
    public func setManualIONoReflow(_ value: Bool) {
        guard manualIONoReflow != value else { return }
        manualIONoReflow = value
    }

    /// Inject remote tmux `%output` into the terminal parser. If the Ghostty
    /// runtime is not live yet, buffer a bounded tail and flush it on creation.
    @MainActor
    public func processRemoteOutput(_ data: Data) {
        guard !data.isEmpty else { return }
        guard let surface = liveSurfaceForGhosttyAccess(reason: "remoteOutput") else {
            pendingRemoteOutput.append(data)
            if pendingRemoteOutput.count > maxPendingRemoteOutputBytes {
                pendingRemoteOutput.removeFirst(pendingRemoteOutput.count - maxPendingRemoteOutputBytes)
            }
            return
        }
        flushPendingRemoteOutput(to: surface)
        writeProcessOutputData(data, to: surface)
        ghostty_surface_refresh(surface)
    }

    @MainActor
    func flushPendingRemoteOutput(to surface: ghostty_surface_t) {
        guard !pendingRemoteOutput.isEmpty else { return }
        let buffered = pendingRemoteOutput
        pendingRemoteOutput = Data()
        writeProcessOutputData(buffered, to: surface)
    }

    static func readText(
        surface: ghostty_surface_t,
        pointTag: ghostty_point_tag_e
    ) -> String? {
        let topLeft = ghostty_point_s(
            tag: pointTag,
            coord: GHOSTTY_POINT_COORD_TOP_LEFT,
            x: 0,
            y: 0
        )
        let bottomRight = ghostty_point_s(
            tag: pointTag,
            coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
            x: 0,
            y: 0
        )
        let selection = ghostty_selection_s(
            top_left: topLeft,
            bottom_right: bottomRight,
            rectangle: false
        )

        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &text) else {
            return nil
        }
        defer {
            ghostty_surface_free_text(surface, &text)
        }

        guard let ptr = text.text, text.text_len > 0 else {
            return ""
        }
        let rawData = Data(bytes: ptr, count: Int(text.text_len))
        return String(decoding: rawData, as: UTF8.self)
    }

    private func keycodeForLetter(_ letter: Character) -> UInt32? {
        switch String(letter).lowercased() {
        case "a": return UInt32(kVK_ANSI_A)
        case "b": return UInt32(kVK_ANSI_B)
        case "c": return UInt32(kVK_ANSI_C)
        case "d": return UInt32(kVK_ANSI_D)
        case "e": return UInt32(kVK_ANSI_E)
        case "f": return UInt32(kVK_ANSI_F)
        case "g": return UInt32(kVK_ANSI_G)
        case "h": return UInt32(kVK_ANSI_H)
        case "i": return UInt32(kVK_ANSI_I)
        case "j": return UInt32(kVK_ANSI_J)
        case "k": return UInt32(kVK_ANSI_K)
        case "l": return UInt32(kVK_ANSI_L)
        case "m": return UInt32(kVK_ANSI_M)
        case "n": return UInt32(kVK_ANSI_N)
        case "o": return UInt32(kVK_ANSI_O)
        case "p": return UInt32(kVK_ANSI_P)
        case "q": return UInt32(kVK_ANSI_Q)
        case "r": return UInt32(kVK_ANSI_R)
        case "s": return UInt32(kVK_ANSI_S)
        case "t": return UInt32(kVK_ANSI_T)
        case "u": return UInt32(kVK_ANSI_U)
        case "v": return UInt32(kVK_ANSI_V)
        case "w": return UInt32(kVK_ANSI_W)
        case "x": return UInt32(kVK_ANSI_X)
        case "y": return UInt32(kVK_ANSI_Y)
        case "z": return UInt32(kVK_ANSI_Z)
        default: return nil
        }
    }

    private func keycodeForNamedKey(_ name: String) -> UInt32? {
        switch name {
        case "enter", "return": return UInt32(kVK_Return)
        case "tab": return UInt32(kVK_Tab)
        case "escape", "esc": return UInt32(kVK_Escape)
        case "backspace": return UInt32(kVK_Delete)
        case "delete": return UInt32(kVK_ForwardDelete)
        case "space": return UInt32(kVK_Space)
        case "up": return UInt32(kVK_UpArrow)
        case "down": return UInt32(kVK_DownArrow)
        case "left": return UInt32(kVK_LeftArrow)
        case "right": return UInt32(kVK_RightArrow)
        case "\\": return UInt32(kVK_ANSI_Backslash)
        default: return nil
        }
    }

    func pendingKeyEvent(for keyName: String) -> PendingKeyEvent? {
        let normalized = keyName.lowercased()
        switch normalized {
        case "ctrl-c", "ctrl+c", "sigint":
            return PendingKeyEvent(keycode: UInt32(kVK_ANSI_C), mods: GHOSTTY_MODS_CTRL, label: normalized)
        case "ctrl-d", "ctrl+d", "eof":
            return PendingKeyEvent(keycode: UInt32(kVK_ANSI_D), mods: GHOSTTY_MODS_CTRL, label: normalized)
        case "ctrl-f", "ctrl+f":
            // Force-stop chord for embedded TUIs (e.g. Claude Code's "Ctrl-F twice").
            return PendingKeyEvent(keycode: UInt32(kVK_ANSI_F), mods: GHOSTTY_MODS_CTRL, label: normalized)
        case "ctrl-z", "ctrl+z", "sigtstp":
            return PendingKeyEvent(keycode: UInt32(kVK_ANSI_Z), mods: GHOSTTY_MODS_CTRL, label: normalized)
        case "ctrl-\\", "ctrl+\\", "sigquit":
            return PendingKeyEvent(keycode: UInt32(kVK_ANSI_Backslash), mods: GHOSTTY_MODS_CTRL, label: normalized)
        case "enter", "return":
            return PendingKeyEvent(keycode: UInt32(kVK_Return), mods: GHOSTTY_MODS_NONE, label: normalized)
        case "tab":
            return PendingKeyEvent(keycode: UInt32(kVK_Tab), mods: GHOSTTY_MODS_NONE, label: normalized)
        case "escape", "esc":
            return PendingKeyEvent(keycode: UInt32(kVK_Escape), mods: GHOSTTY_MODS_NONE, label: normalized)
        case "backspace":
            return PendingKeyEvent(keycode: UInt32(kVK_Delete), mods: GHOSTTY_MODS_NONE, label: normalized)
        case "up", "arrow_up", "arrowup":
            return PendingKeyEvent(keycode: UInt32(kVK_UpArrow), mods: GHOSTTY_MODS_NONE, label: normalized)
        case "down", "arrow_down", "arrowdown":
            return PendingKeyEvent(keycode: UInt32(kVK_DownArrow), mods: GHOSTTY_MODS_NONE, label: normalized)
        case "left", "arrow_left", "arrowleft":
            return PendingKeyEvent(keycode: UInt32(kVK_LeftArrow), mods: GHOSTTY_MODS_NONE, label: normalized)
        case "right", "arrow_right", "arrowright":
            return PendingKeyEvent(keycode: UInt32(kVK_RightArrow), mods: GHOSTTY_MODS_NONE, label: normalized)
        case "shift+tab", "shift-tab", "backtab":
            return PendingKeyEvent(keycode: UInt32(kVK_Tab), mods: GHOSTTY_MODS_SHIFT, label: normalized)
        case "home":
            return PendingKeyEvent(keycode: UInt32(kVK_Home), mods: GHOSTTY_MODS_NONE, label: normalized)
        case "end":
            return PendingKeyEvent(keycode: UInt32(kVK_End), mods: GHOSTTY_MODS_NONE, label: normalized)
        case "delete", "del", "forward_delete":
            return PendingKeyEvent(keycode: UInt32(kVK_ForwardDelete), mods: GHOSTTY_MODS_NONE, label: normalized)
        case "pageup", "page_up":
            return PendingKeyEvent(keycode: UInt32(kVK_PageUp), mods: GHOSTTY_MODS_NONE, label: normalized)
        case "pagedown", "page_down":
            return PendingKeyEvent(keycode: UInt32(kVK_PageDown), mods: GHOSTTY_MODS_NONE, label: normalized)
        default:
            let parts = normalized
                .split(separator: "+")
                .flatMap { $0.split(separator: "-") }
                .map(String.init)
                .filter { !$0.isEmpty }
            guard let baseKey = parts.last else { return nil }

            if parts.count == 1 {
                if let keycode = keycodeForNamedKey(baseKey) {
                    return PendingKeyEvent(keycode: keycode, mods: GHOSTTY_MODS_NONE, label: normalized)
                }
                if baseKey.count == 1,
                   let char = baseKey.first,
                   let keycode = keycodeForLetter(char) {
                    return PendingKeyEvent(keycode: keycode, mods: GHOSTTY_MODS_NONE, label: normalized)
                }
                return nil
            }

            var mods = GHOSTTY_MODS_NONE
            for mod in parts.dropLast() {
                switch mod {
                case "ctrl", "control":
                    mods = ghostty_input_mods_e(rawValue: mods.rawValue | GHOSTTY_MODS_CTRL.rawValue)
                case "shift":
                    mods = ghostty_input_mods_e(rawValue: mods.rawValue | GHOSTTY_MODS_SHIFT.rawValue)
                case "alt", "opt", "option":
                    mods = ghostty_input_mods_e(rawValue: mods.rawValue | GHOSTTY_MODS_ALT.rawValue)
                case "cmd", "command", "super":
                    mods = ghostty_input_mods_e(rawValue: mods.rawValue | GHOSTTY_MODS_SUPER.rawValue)
                default:
                    return nil
                }
            }

            if let keycode = keycodeForNamedKey(baseKey) {
                return PendingKeyEvent(keycode: keycode, mods: mods, label: normalized)
            }
            if baseKey.count == 1,
               let char = baseKey.first,
               let keycode = keycodeForLetter(char) {
                return PendingKeyEvent(keycode: keycode, mods: mods, label: normalized)
            }
            return nil
        }
    }

    @MainActor
    private func enqueuePendingSocketInput(_ input: PendingSocketInput) -> Bool {
        enqueuePendingSocketInputs([input])
    }

    @MainActor
    func enqueuePendingSocketInputs(_ inputs: [PendingSocketInput]) -> Bool {
        let incomingBytes = inputs.reduce(0) { $0 + $1.estimatedBytes }
        guard incomingBytes > 0 else { return true }

        guard incomingBytes <= maxPendingSocketInputBytes,
              pendingSocketInputBytes + incomingBytes <= maxPendingSocketInputBytes else {
#if DEBUG
            logDebugEvent(
                "surface.socket_input.reject surface=\(id.uuidString.prefix(8)) " +
                "items=\(inputs.count) incomingBytes=\(incomingBytes) pendingBytes=\(pendingSocketInputBytes)"
            )
#endif
            return false
        }

        pendingSocketInputQueue.append(contentsOf: inputs)
        pendingSocketInputBytes += incomingBytes
#if DEBUG
        let pendingKeys = pendingSocketInputQueue.reduce(into: 0) { count, item in
            if case .key = item {
                count += 1
            }
        }
        logDebugEvent(
            "surface.socket_input.queue surface=\(id.uuidString.prefix(8)) items=\(pendingSocketInputQueue.count) " +
            "keys=\(pendingKeys) bytes=\(pendingSocketInputBytes)"
        )
#endif
        return true
    }

    @MainActor
    func flushPendingSocketInputIfNeeded() {
        guard let surface = liveSurfaceForSocketWrite(reason: "socket.flushPendingInput") else { return }
        let queued = pendingSocketInputQueue
        let queuedBytes = pendingSocketInputBytes
        pendingSocketInputQueue.removeAll(keepingCapacity: false)
        pendingSocketInputBytes = 0
        guard !queued.isEmpty else { return }

        var queuedKeys = 0
        for item in queued {
            switch item {
            case .pasteText(let chunk):
                writeTextData(chunk, to: surface)
            case .inputText(let chunk):
                writeInputTextData(chunk, to: surface)
            case .processOutput(let chunk):
                writeProcessOutputData(chunk, to: surface)
            case .key(let event):
                queuedKeys += 1
                sendKeyEvent(surface: surface, keycode: event.keycode, mods: event.mods)
            }
        }
#if DEBUG
        logDebugEvent(
            "surface.socket_input.flush surface=\(id.uuidString.prefix(8)) items=\(queued.count) " +
            "keys=\(queuedKeys) bytes=\(queuedBytes)"
        )
#endif
    }
}
