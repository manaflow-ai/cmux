import AppKit
import CmuxTerminal
import CmuxSettings
import CmuxTerminalCore

extension GhosttyNSView {
    /// Joins rows Ghostty marks as soft-wrapped before the selection is published.
    ///
    /// Ghostty's clipboard formatter already does this when `unwrap` is on. When
    /// the emitted plain text still has one line per physical row, the wrap
    /// flags from a paired screen read finish the join. Hard-wrap reflow runs
    /// only when `terminal.reflowHardWrapOnCopy` is set.
    func joinedCopyText(
        _ text: String,
        surface: ghostty_surface_t,
        joiningEnabled: Bool
    ) -> String {
        guard joiningEnabled, text.contains("\n") else { return text }
        let copy = TerminalSoftWrapCopy(
            hardWrapReflow: TerminalCatalogSection().reflowHardWrapOnCopy.value(in: .standard),
            terminalColumns: Int(ghostty_surface_size(surface).columns)
        )
        return copy.joiningSoftWraps(
            in: text,
            wrapFlags: ghosttySelectionRowWrapFlags(
                surface: surface,
                matchingLineCount: copy.physicalLineCount(in: text)
            )
        )
    }

    /// Copies the current selection with terminal wrapping removed.
    @IBAction func copyUnwrapped(_ sender: Any?) {
        guard let surface,
              let snapshot = readSelectionSnapshot(surface: surface),
              !snapshot.string.isEmpty else { return }
        let columns = Int(ghostty_surface_size(surface).columns)
        let rectangular = !isKeyboardCopyModeActive && copySelectionMayBeRectangular
        let copy = TerminalSoftWrapCopy(hardWrapReflow: false)
        let joined = rectangular ? snapshot.string : copy.joiningSoftWraps(in: snapshot.string,
            wrapFlags: ghosttySelectionRowWrapFlags(
                surface: surface,
                matchingLineCount: copy.physicalLineCount(in: snapshot.string)
            )
        )
        let unwrapped = TerminalUnwrappedCopy(
            terminalColumns: columns, rectangular: rectangular,
            firstLineStartColumn: snapshot.topLeft.x >= 0 && columns > 0 ? snapshot.range.location % columns : nil
        ).unwrappedText(joined)
        GhosttyApp.terminalPasteboard.writeString(unwrapped, to: GHOSTTY_CLIPBOARD_STANDARD)
    }

    func addCopyUnwrappedMenuItem(to menu: NSMenu) {
        let item = menu.addItem(
            withTitle: String(localized: "terminalContextMenu.copyUnwrapped", defaultValue: "Copy Unwrapped"),
            action: #selector(copyUnwrapped(_:)), keyEquivalent: ""
        )
        item.target = self
        let shortcut = KeyboardShortcutSettings.menuShortcut(for: .copyUnwrapped)
        item.keyEquivalent = shortcut.menuItemKeyEquivalent ?? ""
        item.keyEquivalentModifierMask = shortcut.menuItemKeyEquivalent == nil ? [] : shortcut.modifierFlags
    }

    func recordDirectAgentHibernationTerminalInput() {
        guard let terminalSurface else { return }
        GhosttyApp.terminalSurfaceRuntimeDependencies
            .hibernationRecorder.recordTerminalInput(
                workspaceId: terminalSurface.tabId,
                panelId: terminalSurface.id
            )
    }

    @IBAction func paste(_ sender: Any?) {
        guard prepareSurfaceForPaste(reason: "paste.missingSurface") else {
            return
        }
        recordDirectAgentHibernationTerminalInput()
        if performBindingAction("paste_from_clipboard") {
            terminalSurface?.didAcceptExplicitInput()
        }
    }

    /// Pastes clipboard text as plain text, stripping any rich formatting.
    @IBAction func pasteAsPlainText(_ sender: Any?) {
        guard prepareSurfaceForPaste(
            reason: "pasteAsPlainText.missingSurface"
        ) else {
            return
        }
        recordDirectAgentHibernationTerminalInput()
        if performBindingAction("paste_from_clipboard") {
            terminalSurface?.didAcceptExplicitInput()
        }
    }

    /// The clipboard's plain text when it spans several lines, the case where
    /// "Paste as One Line" differs from Paste.
    var multiLineClipboardPlainText: String? {
        guard let pasteboard = GhosttyApp.terminalPasteboard.pasteboard(for: GHOSTTY_CLIPBOARD_STANDARD),
              let text = GhosttyApp.terminalPasteboard.fallbackPlainTextContents(from: pasteboard),
              TerminalPasteLineJoin(text).spansMultipleLines else {
            return nil
        }
        return text
    }

    /// Pastes the clipboard's plain text with its line breaks joined into one
    /// line, so a command that was copied with a break at every wrap point
    /// reaches the shell whole. It goes through the same paste path as
    /// `cmux paste` and never presses Return.
    @IBAction func pasteAsOneLine(_ sender: Any?) {
        guard let text = multiLineClipboardPlainText else { return }
        let joined = TerminalPasteLineJoin(text).joined
        guard !joined.isEmpty else { return }
        _ = terminalSurface?.sendTextResult(joined)
    }
}
