import SwiftUI

/// A menu of structural table operations for the inline Markdown editor.
struct MarkdownTableToolbar: View {
    let onAction: (MarkdownFormattingAction) -> Void

    private let actions: [MarkdownFormattingAction] = [
        .insertTable,
        .tableAddRowBefore,
        .tableAddRowAfter,
        .tableAddColumnBefore,
        .tableAddColumnAfter,
        .tableDeleteRow,
        .tableDeleteColumn,
        .tableToggleHeader
    ]

    var body: some View {
        Menu {
            ForEach(actions) { action in
                Button {
                    onAction(action)
                } label: {
                    Label(action.label, systemImage: action.systemImage)
                }
            }
        } label: {
            PanelHeaderIconGlyph(systemName: "tablecells")
        }
        .menuStyle(.borderlessButton)
        .foregroundColor(.secondary)
        .help(String(localized: "markdown.format.tableMenu", defaultValue: "Table actions"))
        .accessibilityLabel(String(localized: "markdown.format.tableMenu", defaultValue: "Table actions"))
    }
}
