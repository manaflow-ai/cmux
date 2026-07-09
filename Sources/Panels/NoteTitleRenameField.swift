import AppKit
import SwiftUI

/// Zed-style inline rename for a note's title: idle it is a PLAIN text label
/// (no AppKit field exists, so no caret, cursor rect, or focus artifact can
/// ever appear in the header), with a subtle underline on hover. Clicking
/// swaps in an editable field focused with the title selected. Enter or
/// clicking away commits through `onRename`; Escape restores the committed
/// title. The committed title stays authoritative — external retitles (tree
/// rename, another panel) always win over an idle label and never interrupt
/// an in-progress edit.
struct NoteTitleRenameField: View {
    let title: String
    let filePath: String
    let foregroundColor: NSColor
    var onBeginEditing: () -> Void = {}
    let onRename: (String) -> Void

    @State private var draft: String = ""
    @State private var isHovering = false
    @State private var isFocused = false
    @State private var isEditing = false

    private var placeholder: String {
        String(localized: "note.title.placeholder", defaultValue: "Untitled note")
    }

    private var titleFont: Font {
        .system(size: 12, weight: .regular)
    }

    private var titleNSFont: NSFont {
        .systemFont(ofSize: 12, weight: .regular)
    }

    var body: some View {
        Group {
            if isEditing {
                editingField
            } else {
                idleLabel
            }
        }
        .frame(minWidth: 40, minHeight: 20, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .layoutPriority(1)
        .onHover { isHovering = $0 }
        .help(filePath)
        .accessibilityLabel(String(localized: "note.title.accessibility", defaultValue: "Note title"))
    }

    private var idleLabel: some View {
        Text(title.isEmpty ? placeholder : title)
            .font(titleFont)
            .foregroundStyle(Color(nsColor: foregroundColor).opacity(title.isEmpty ? 0.42 : 0.88))
            .lineLimit(1)
            .truncationMode(.tail)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color(nsColor: foregroundColor).opacity(0.22))
                    .frame(height: 1)
                    .opacity(isHovering ? 1 : 0)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                onBeginEditing()
                draft = title
                isEditing = true
            }
    }

    private var editingField: some View {
        // Size the editable field from label text so the title behaves like
        // the other compact panel headers while still accepting in-place edits.
        Text(draft.isEmpty ? placeholder : draft)
            .font(titleFont)
            .lineLimit(1)
            .truncationMode(.tail)
            .opacity(0)
            .accessibilityHidden(true)
            .overlay(alignment: .leading) {
                NoteTitleTextFieldRepresentable(
                    placeholder: placeholder,
                    text: $draft,
                    isFocused: $isFocused,
                    font: titleNSFont,
                    foregroundColor: foregroundColor,
                    focusOnAttach: true,
                    onBeginEditing: onBeginEditing,
                    onCommit: commit,
                    onCancel: cancel
                )
            }
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color.accentColor.opacity(0.65))
                    .frame(height: 1)
            }
    }

    private func cancel() {
        draft = title
        isEditing = false
    }

    private func commit() {
        defer { isEditing = false }
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != title else {
            draft = title
            return
        }
        onRename(trimmed)
        // The rename is async and can fail (index write, invalid slug). Keep the
        // committed title authoritative: the idle label renders `title`, and the
        // rename's retitle notification delivers the new title through it.
        draft = title
    }
}
