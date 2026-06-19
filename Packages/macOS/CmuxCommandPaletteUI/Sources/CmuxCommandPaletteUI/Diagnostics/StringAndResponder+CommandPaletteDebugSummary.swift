#if DEBUG
public import AppKit

extension String {
    /// DEBUG-only escaped, length-capped preview of this string for the
    /// command-palette debug log. Escapes backslash and CR/LF/tab, then
    /// truncates to `limit` characters with a trailing `...`.
    public func commandPaletteDebugPreview(limit: Int = 120) -> String {
        let escaped = self
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
        if escaped.count <= limit {
            return escaped
        }
        let prefix = escaped.prefix(limit)
        return "\(prefix)..."
    }
}

extension NSResponder {
    /// DEBUG-only summary of this responder, surfacing text-input editor state
    /// (field-editor/editable/selection/length) when the responder is a text
    /// view or text field, for the command-palette focus debug log.
    @MainActor
    public var commandPaletteResponderDebugSummary: String {
        let typeName = String(describing: type(of: self))
        if let textView = self as? NSTextView {
            let selection = textView.selectedRange()
            return "\(typeName){fieldEditor=\(textView.isFieldEditor ? 1 : 0) editable=\(textView.isEditable ? 1 : 0) selectable=\(textView.isSelectable ? 1 : 0) hidden=\(textView.isHiddenOrHasHiddenAncestor ? 1 : 0) len=\((textView.string as NSString).length) sel=\(selection.location):\(selection.length)}"
        }

        if let textField = self as? NSTextField {
            return "\(typeName){editable=\(textField.isEditable ? 1 : 0) enabled=\(textField.isEnabled ? 1 : 0) hidden=\(textField.isHiddenOrHasHiddenAncestor ? 1 : 0) len=\((textField.stringValue as NSString).length)}"
        }

        if let view = self as? NSView {
            return "\(typeName){hidden=\(view.isHiddenOrHasHiddenAncestor ? 1 : 0)}"
        }

        return typeName
    }
}

extension Optional where Wrapped == NSResponder {
    /// DEBUG-only summary that renders `"nil"` for a missing responder,
    /// otherwise delegates to ``AppKit/NSResponder/commandPaletteResponderDebugSummary``.
    @MainActor
    public var commandPaletteResponderDebugSummary: String {
        self?.commandPaletteResponderDebugSummary ?? "nil"
    }
}
#endif
