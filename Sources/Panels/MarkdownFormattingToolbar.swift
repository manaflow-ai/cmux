import SwiftUI

/// A formatting transaction understood by the inline Markdown editor.
enum MarkdownFormattingAction: String, CaseIterable, Identifiable {
    case undo
    case redo
    case bold
    case italic
    case strikethrough
    case heading1
    case heading2
    case bulletList
    case numberedList
    case quote
    case codeBlock
    case insertTable
    case tableAddRowBefore
    case tableAddRowAfter
    case tableAddColumnBefore
    case tableAddColumnAfter
    case tableDeleteRow
    case tableDeleteColumn
    case tableToggleHeader

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .undo: "arrow.uturn.backward"
        case .redo: "arrow.uturn.forward"
        case .bold: "bold"
        case .italic: "italic"
        case .strikethrough: "strikethrough"
        case .heading1: "textformat.size.larger"
        case .heading2: "textformat.size"
        case .bulletList: "list.bullet"
        case .numberedList: "list.number"
        case .quote: "text.quote"
        case .codeBlock: "chevron.left.forwardslash.chevron.right"
        case .insertTable: "tablecells"
        case .tableAddRowBefore: "rectangle.topthird.inset.filled"
        case .tableAddRowAfter: "rectangle.bottomthird.inset.filled"
        case .tableAddColumnBefore: "rectangle.leadingthird.inset.filled"
        case .tableAddColumnAfter: "rectangle.trailingthird.inset.filled"
        case .tableDeleteRow: "rectangle.split.1x2"
        case .tableDeleteColumn: "rectangle.split.2x1"
        case .tableToggleHeader: "tablecells.badge.ellipsis"
        }
    }

    var label: String {
        switch self {
        case .undo:
            String(localized: "markdown.format.undo", defaultValue: "Undo")
        case .redo:
            String(localized: "markdown.format.redo", defaultValue: "Redo")
        case .bold:
            String(localized: "markdown.format.bold", defaultValue: "Bold")
        case .italic:
            String(localized: "markdown.format.italic", defaultValue: "Italic")
        case .strikethrough:
            String(localized: "markdown.format.strikethrough", defaultValue: "Strikethrough")
        case .heading1:
            String(localized: "markdown.format.heading1", defaultValue: "Heading 1")
        case .heading2:
            String(localized: "markdown.format.heading2", defaultValue: "Heading 2")
        case .bulletList:
            String(localized: "markdown.format.bulletList", defaultValue: "Bullet list")
        case .numberedList:
            String(localized: "markdown.format.numberedList", defaultValue: "Numbered list")
        case .quote:
            String(localized: "markdown.format.quote", defaultValue: "Quote")
        case .codeBlock:
            String(localized: "markdown.format.codeBlock", defaultValue: "Code block")
        case .insertTable:
            String(localized: "markdown.format.insertTable", defaultValue: "Insert table")
        case .tableAddRowBefore:
            String(localized: "markdown.format.tableAddRowBefore", defaultValue: "Add row above")
        case .tableAddRowAfter:
            String(localized: "markdown.format.tableAddRowAfter", defaultValue: "Add row below")
        case .tableAddColumnBefore:
            String(localized: "markdown.format.tableAddColumnBefore", defaultValue: "Add column before")
        case .tableAddColumnAfter:
            String(localized: "markdown.format.tableAddColumnAfter", defaultValue: "Add column after")
        case .tableDeleteRow:
            String(localized: "markdown.format.tableDeleteRow", defaultValue: "Delete row")
        case .tableDeleteColumn:
            String(localized: "markdown.format.tableDeleteColumn", defaultValue: "Delete column")
        case .tableToggleHeader:
            String(localized: "markdown.format.tableToggleHeader", defaultValue: "Toggle header row")
        }
    }
}

/// Compact formatting controls for the rendered Markdown editor.
struct MarkdownFormattingToolbar: View {
    let onAction: (MarkdownFormattingAction) -> Void

    var body: some View {
        HStack(spacing: 2) {
            toolbarButton(.undo)
            toolbarButton(.redo)
            Divider().frame(height: 16)
            toolbarButton(.bold)
            toolbarButton(.italic)
            toolbarButton(.strikethrough)
            Divider().frame(height: 16)
            toolbarButton(.heading1)
            toolbarButton(.heading2)
            toolbarButton(.bulletList)
            toolbarButton(.numberedList)
            toolbarButton(.quote)
            toolbarButton(.codeBlock)
        }
    }

    private func toolbarButton(_ action: MarkdownFormattingAction) -> some View {
        PanelHeaderIconButton(
            systemName: action.systemImage,
            label: action.label,
            action: { onAction(action) }
        )
    }
}
