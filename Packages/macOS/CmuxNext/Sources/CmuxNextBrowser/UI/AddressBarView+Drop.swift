public import AppKit

/// Drops on the omnibar (Chromium `OmniboxViewViews::PerformDrop`): a dropped URL, else dropped text,
/// replaces the box's text; the box takes focus with all of it selected, and nothing loads until
/// Enter. The bar takes drops at rest; while editing its field editor hands them here
/// (`OmnibarFieldEditor`), so a drop never inserts at the pointer.
extension AddressBarView {
    /// The pasteboard types the omnibar takes.
    static let dropTypes: [NSPasteboard.PasteboardType] = [.URL, .fileURL, .string]

    /// What a drop from `pasteboard` would put in the box: its first URL (a file URL as its
    /// path URL, Chromium `FilenameToURLPolicy::CONVERT_FILENAMES`), else its text; nil for neither.
    static func dropText(from pasteboard: NSPasteboard) -> String? {
        if let url = NSURL(from: pasteboard)?.absoluteString, !url.isEmpty {
            return url
        }
        guard let text = pasteboard.string(forType: .string), !OmnibarRules.droppedText(text).isEmpty else { return nil }
        return text
    }

    /// Takes a drop from `pasteboard`: focuses the field (the URL selected, as a programmatic focus
    /// shows it) and hands the dropped text to the state machine. Returns false when the pasteboard
    /// holds nothing the box shows, or the bar is read-only.
    @discardableResult
    func acceptDrop(from pasteboard: NSPasteboard) -> Bool {
        acceptDrop(Self.dropText(from: pasteboard))
    }

    /// Takes dropped `text` (``dropText(from:)``'s answer): focuses the field and hands the text to
    /// the state machine. Returns false for nil text or a read-only bar.
    @discardableResult
    func acceptDrop(_ text: String?) -> Bool {
        guard !isReadOnly, let text else { return false }
        if field.currentEditor() == nil {
            pendingFocusSource = .programmatic
            window?.makeFirstResponder(field)
            pendingFocusSource = nil
        }
        // A view outside a window (or a field that refused focus) still takes the text once focused.
        if !controller.state.hasFocus { controller.send(.focusGained(.programmatic)) }
        return controller.send(.dropped(text))
    }

    public override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        !isReadOnly && Self.dropText(from: sender.draggingPasteboard) != nil ? .copy : []
    }

    public override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        acceptDrop(from: sender.draggingPasteboard)
    }
}
