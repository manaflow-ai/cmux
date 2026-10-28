public import AppKit
import Carbon.HIToolbox
import CmuxNextDesign
import GhosttyNextKit
import UniformTypeIdentifiers

// MARK: - Copy/paste, context menu, drag and drop (clipboard requests: TerminalClipboardRequests)

extension TerminalSurfaceView: NSMenuItemValidation {
    // MARK: Edit menu

    /// Copies the selection. With nothing selected, Copy is Cmd-C for the
    /// program, so a TUI (Kitty keyboard protocol: Claude Code, Codex) copies
    /// its own selection, as in Ghostty and the shipping cmux. For a program
    /// that reads the mouse (it draws that selection) the PTY owner encodes it
    /// with the program's keyboard modes (`TerminalKeyEquivalent.sendToProgram`);
    /// otherwise the key goes to Ghostty, whose `performable:` copy keybind
    /// passes it on. Legacy encoding sends nothing for a Command key on macOS,
    /// so a shell sees nothing.
    @objc public func copy(_ sender: Any?) {
        guard hasSelection else {
            let local: @MainActor () -> Void = { [weak self] in self?.sendCommandKeyToProgram("c", keyCode: UInt16(kVK_ANSI_C)) }
            if programCapturesMouse, let session, TerminalKeyEquivalent.sendToProgram?(session, "super+c", local) == true { return }
            local()
            return
        }
        clipboardRequests.asUserClipboardWrite { performBindingAction("copy_to_clipboard") }
    }

    /// Whether the program asked for mouse reports, so it draws its own selection and owns its
    /// editing keys (a TUI such as Claude Code fullscreen, Codex or OpenCode).
    public var programCapturesMouse: Bool {
        guard let surface else { return false }
        // SAFETY: the view's live surface (TerminalSurfaceView.surface).
        return unsafe ghostty_surface_mouse_captured(surface)
    }

    private func sendCommandKeyToProgram(_ character: String, keyCode: UInt16) {
        for (type, action) in [(NSEvent.EventType.keyDown, GHOSTTY_ACTION_PRESS), (.keyUp, GHOSTTY_ACTION_RELEASE)] {
            guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: .command,
                                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window?.windowNumber ?? 0,
                                               context: nil, characters: character, charactersIgnoringModifiers: character,
                                               isARepeat: false, keyCode: keyCode) else { return }
            sendKey(action, event: event, text: action == GHOSTTY_ACTION_PRESS ? character : nil)
        }
    }

    @objc public func paste(_ sender: Any?) {
        clipboardRequests.asUserPaste { performBindingAction("paste_from_clipboard") }
    }

    @objc public func pasteAsPlainText(_ sender: Any?) {
        performBindingAction("paste_from_clipboard")
    }

    @objc public override func selectAll(_ sender: Any?) {
        performBindingAction("select_all")
    }

    public func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)):
            // Enabled without a selection too: a disabled item would swallow
            // Cmd-C before the program can get it (see `copy(_:)`).
            return surface != nil
        case #selector(paste(_:)), #selector(pasteAsPlainText(_:)):
            return TerminalPasteboard.pasteText(from: .general) != nil || TerminalPasteboard.hasImage(.general)
        default:
            return true
        }
    }

    public override func menu(for event: NSEvent) -> NSMenu? {
        // The terminal's rows highlight as the sidebar's and the tab strip's do: a wash of its theme's accent.
        if let session, let menu = session.delegate?.terminalSession(session, contextMenuFor: event) { return menu.themeRows(in: themeScope.fullStrength) }
        let menu = NSMenu()
        if hasSelection {
            menu.addItem(withTitle: String(localized: "terminal.menu.copy", defaultValue: "Copy", bundle: .module), action: #selector(copy(_:)), keyEquivalent: "")
        }
        menu.addItem(withTitle: String(localized: "terminal.menu.paste", defaultValue: "Paste", bundle: .module), action: #selector(paste(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "terminal.menu.selectAll", defaultValue: "Select All", bundle: .module), action: #selector(selectAll(_:)), keyEquivalent: "")
        for item in menu.items { item.target = self }
        return menu
    }

    // MARK: Drag and drop

    public override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        TerminalPasteboard.pasteText(from: sender.draggingPasteboard) == nil ? [] : .copy
    }

    /// Dropped files paste as shell-escaped paths, dropped text as text (``pasteDropped(_:)``).
    public override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let text = TerminalPasteboard.pasteText(from: sender.draggingPasteboard), pasteDropped(text) else { return false }
        window?.makeFirstResponder(self)
        return true
    }

    /// Sends dropped `text` to the terminal as a paste, so paste protection asks before a line break
    /// (a carriage return too) reaches an unbracketed shell, as Cmd-V of the same text does (Ghostty
    /// 1.4.0, 5580df602 and 5c9a3d8a9). This GhosttyNextKit has no `ghostty_surface_paste_text`, so
    /// the drop runs the `paste_from_clipboard` binding with its clipboard read served the dropped
    /// text (``TerminalClipboardRequests/asDrop(_:paste:)``): Ghostty's own paste path, with bracketed
    /// paste and the `clipboard-paste-*` settings. False without a live surface.
    func pasteDropped(_ text: String) -> Bool {
        guard surface != nil else { return false }
        let text = TerminalPasteboard.normalizedLineEndings(text)
        guard !text.isEmpty else { return true }
        if clipboardRequests.asDrop(text, paste: { _ = performBindingAction("paste_from_clipboard") }) { return true }
        // A program that reads paste events (kitty mode 5522) gets none for a drop, which would let it
        // read the real clipboard: the drop goes in as text after the same check and prompt.
        clipboardRequests.confirmDrop(text) { [weak self] in
            guard let surface = self?.surface else { return }
            // SAFETY: the view's live surface (TerminalSurfaceView.surface); Swift passes a NUL-terminated
            // copy of `text` for the call, its length without the NUL, and Ghostty copies what it keeps.
            unsafe ghostty_surface_text(surface, text, UInt(text.utf8.count))
        }
        return true
    }
}
