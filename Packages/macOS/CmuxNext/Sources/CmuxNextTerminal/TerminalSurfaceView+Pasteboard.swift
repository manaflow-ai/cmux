public import AppKit
import Carbon.HIToolbox
import GhosttyKit
import UniformTypeIdentifiers

// MARK: - Clipboard callbacks, copy/paste, context menu, drag and drop

extension TerminalSurfaceView: NSMenuItemValidation {
    func completeClipboardRead(location: TerminalPasteboardLocation, state: UncheckedPointer) -> Bool {
        guard let surface, let text = TerminalPasteboard.pasteText(from: TerminalPasteboard.pasteboard(location)) else {
            return false
        }
        text.withCString { pointer in
            ghostty_surface_complete_clipboard_request(surface, pointer, state.raw, false)
        }
        return true
    }

    /// Unsafe paste (newlines while bracketed paste is off) or an OSC 52 read
    /// when `clipboard-read = ask`. Denial completes with an empty string, as
    /// Ghostty expects.
    func confirmClipboardRequest(contents: String, kind: TerminalClipboardRequestKind, state: UncheckedPointer) {
        guard let window else {
            complete(state: state, with: "")
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        switch kind {
        case .paste:
            alert.messageText = String(localized: "terminal.clipboard.paste.title", defaultValue: "Paste into the terminal?", bundle: .module)
            alert.informativeText = String(localized: "terminal.clipboard.paste.message", defaultValue: "The text contains line breaks and may run commands immediately.", bundle: .module)
        case .osc52Read, .osc52Write:
            alert.messageText = String(localized: "terminal.clipboard.read.title", defaultValue: "Allow a program to read the clipboard?", bundle: .module)
            alert.informativeText = String(localized: "terminal.clipboard.read.message", defaultValue: "A program running in this terminal asked for the clipboard contents.", bundle: .module)
        }
        alert.accessoryView = Self.previewField(contents)
        alert.addButton(withTitle: String(localized: "terminal.clipboard.allow", defaultValue: "Allow", bundle: .module))
        alert.addButton(withTitle: String(localized: "terminal.clipboard.deny", defaultValue: "Deny", bundle: .module))
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                self?.complete(state: state, with: response == .alertFirstButtonReturn ? contents : "")
            }
        }
    }

    /// OSC 52 write when `clipboard-write = ask`.
    func confirmClipboardWrite(items: [TerminalClipboardItem], location: TerminalPasteboardLocation) {
        guard let window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "terminal.clipboard.write.title", defaultValue: "Allow a program to change the clipboard?", bundle: .module)
        alert.informativeText = String(localized: "terminal.clipboard.write.message", defaultValue: "A program running in this terminal wants to copy text to the clipboard.", bundle: .module)
        alert.accessoryView = Self.previewField(items.first(where: { $0.mime.hasPrefix("text/plain") })?.text ?? items[0].text)
        alert.addButton(withTitle: String(localized: "terminal.clipboard.allow", defaultValue: "Allow", bundle: .module))
        alert.addButton(withTitle: String(localized: "terminal.clipboard.deny", defaultValue: "Deny", bundle: .module))
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated { TerminalPasteboard.write(items, to: location) }
        }
    }

    private func complete(state: UncheckedPointer, with text: String) {
        guard let surface else { return }
        text.withCString { pointer in
            ghostty_surface_complete_clipboard_request(surface, pointer, state.raw, true)
        }
    }

    private static func previewField(_ text: String) -> NSView {
        let limit = 2_000
        let preview = text.count > limit ? String(text.prefix(limit)) + "…" : text
        let field = NSTextField(wrappingLabelWithString: preview)
        field.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        field.textColor = .secondaryLabelColor
        field.maximumNumberOfLines = 8
        field.preferredMaxLayoutWidth = 320
        field.frame = NSRect(x: 0, y: 0, width: 320, height: min(field.intrinsicContentSize.height, 140))
        return field
    }

    // MARK: Edit menu

    @objc public func copy(_ sender: Any?) {
        performBindingAction("copy_to_clipboard")
    }

    @objc public func paste(_ sender: Any?) {
        performBindingAction("paste_from_clipboard")
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
            return hasSelection
        case #selector(paste(_:)), #selector(pasteAsPlainText(_:)):
            return TerminalPasteboard.pasteText(from: .general) != nil
        default:
            return true
        }
    }

    public override func menu(for event: NSEvent) -> NSMenu? {
        if let session, let menu = session.delegate?.terminalSession(session, contextMenuFor: event) { return menu }
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

    /// Dropped files paste as shell-escaped paths, dropped text as text.
    /// Delivered through `ghostty_surface_text` so bracketed paste applies.
    public override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let surface, let text = TerminalPasteboard.pasteText(from: sender.draggingPasteboard) else { return false }
        text.withCString { pointer in
            ghostty_surface_text(surface, pointer, UInt(text.utf8.count))
        }
        window?.makeFirstResponder(self)
        return true
    }
}
