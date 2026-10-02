public import AppKit
import Carbon.HIToolbox
import GhosttyKit
import UniformTypeIdentifiers

// MARK: - Copy/paste, context menu, drag and drop (clipboard requests: TerminalClipboardRequests)

extension TerminalSurfaceView: NSMenuItemValidation {
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
