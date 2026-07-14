import AppKit
import SwiftUI

/// Notion-style page title for note panels: a large, completely chromeless
/// title sitting at the top of the content column. Idle it is plain text
/// (nothing editable exists, so no field chrome, caret, or focus artifact can
/// ever render); clicking swaps in an equally chromeless text field with the
/// caret ready. Enter or clicking away commits through `onRename`; Escape
/// restores the committed title. The committed title stays authoritative —
/// external retitles (Notes tree, `cmux note`, sibling panels) flow back in
/// through `title` and never interrupt an in-progress edit.
struct NotePageTitleView: View {
    let title: String
    let filePath: String
    let foregroundColor: NSColor
    /// Width cap for the page column, mirroring the preview renderer's
    /// `maxContentWidth` so the title lines up with rendered content.
    let maxContentWidth: Double
    /// Routes pane focus to this panel before editing begins, so the focus
    /// system cannot steal the field back mid-click.
    let onBeginEditing: () -> Void
    let onRename: (String) -> Void

    @State private var draft = ""
    @State private var isEditing = false
    @FocusState private var fieldFocused: Bool

    private var placeholder: String {
        String(localized: "note.title.placeholder", defaultValue: "Untitled note")
    }

    private var titleFont: Font {
        .system(size: 22, weight: .bold)
    }

    var body: some View {
        HStack(spacing: 0) {
            Group {
                if isEditing {
                    editingField
                } else {
                    idleTitle
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: CGFloat(maxContentWidth))
        .padding(.horizontal, 24)
        .padding(.top, 14)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .help(filePath)
    }

    private var idleTitle: some View {
        Text(title.isEmpty ? placeholder : title)
            .font(titleFont)
            .foregroundStyle(
                Color(nsColor: foregroundColor).opacity(title.isEmpty ? 0.28 : 0.95)
            )
            .lineLimit(2)
            .truncationMode(.tail)
            .contentShape(Rectangle())
            .onTapGesture {
                onBeginEditing()
                draft = title
                isEditing = true
                fieldFocused = true
            }
            .accessibilityLabel(String(localized: "note.title.accessibility", defaultValue: "Note title"))
            .accessibilityAddTraits(.isButton)
    }

    private var editingField: some View {
        TextField(placeholder, text: $draft)
            .textFieldStyle(.plain)
            .font(titleFont)
            .foregroundStyle(Color(nsColor: foregroundColor).opacity(0.95))
            .focused($fieldFocused)
            .onSubmit(commit)
            .onExitCommand {
                draft = title
                isEditing = false
            }
            .onChange(of: fieldFocused) { _, focused in
                // Clicking anywhere else ends the edit, committing like
                // Notion does (Escape is the explicit cancel above).
                if !focused, isEditing {
                    commit()
                }
            }
            .accessibilityLabel(String(localized: "note.title.accessibility", defaultValue: "Note title"))
    }

    private func commit() {
        defer { isEditing = false }
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != title else { return }
        // The rename applies optimistically inside the panel and reconciles
        // from the store, so the header, tab, and tree repaint exactly once.
        onRename(trimmed)
    }
}
