import Foundation

/// The omnibar's text field as the effect applier sees it (the real
/// `AddressField`, or a fake in tests).
@MainActor protocol OmnibarFieldSurface: AnyObject {
    /// The field editor is attached (the field has AppKit focus).
    var isFieldEditorActive: Bool { get }
    var currentText: String { get }
    var currentSelection: NSRange { get }
    /// IME marked text is pending in the field editor.
    var hasMarkedText: Bool { get }
    func write(_ text: String, style: OmnibarPresentation.Style)
    func select(_ range: NSRange)
}

/// The suggestion card as the effect applier sees it.
@MainActor protocol OmnibarPopupSurface: AnyObject {
    func showRows(_ rows: [BrowserSuggestion], highlighted: Int?)
    func highlightRow(_ row: Int?)
    func dismissRows()
}

/// The only writer of the omnibar field and card. It compares before it
/// writes, so a state that matches the field changes nothing, and it never
/// touches the field while the input method has marked text there.
@MainActor final class OmnibarEffectApplier {
    private struct Written: Equatable {
        var text: String
        var style: OmnibarPresentation.Style
        var editorActive: Bool
    }

    private weak var field: (any OmnibarFieldSurface)?
    private weak var popup: (any OmnibarPopupSurface)?
    private var written: Written?
    private var shownRows: [BrowserSuggestion] = []
    private var shownHighlight: Int?

    /// Field writes so far (tests: no write while composing).
    private(set) var textWrites = 0
    private(set) var selectionWrites = 0

    init(field: any OmnibarFieldSurface, popup: any OmnibarPopupSurface) {
        self.field = field
        self.popup = popup
    }

    func apply(_ presentation: OmnibarPresentation) {
        applyPopup(presentation)
        guard let field, !field.hasMarkedText else { return }
        let signature = Written(text: presentation.text, style: presentation.style, editorActive: field.isFieldEditorActive)
        if field.currentText != presentation.text || written != signature {
            field.write(presentation.text, style: presentation.style)
            textWrites += 1
        }
        written = signature
        if field.isFieldEditorActive, let selection = presentation.selection, field.currentSelection != selection {
            field.select(selection)
            selectionWrites += 1
        }
    }

    private func applyPopup(_ presentation: OmnibarPresentation) {
        guard let popup else { return }
        if presentation.rows.isEmpty {
            if !shownRows.isEmpty { popup.dismissRows() }
        } else if presentation.rows != shownRows {
            popup.showRows(presentation.rows, highlighted: presentation.highlighted)
        } else if presentation.highlighted != shownHighlight {
            popup.highlightRow(presentation.highlighted)
        }
        shownRows = presentation.rows
        shownHighlight = presentation.highlighted
    }
}
