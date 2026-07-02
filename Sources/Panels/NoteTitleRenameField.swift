import AppKit
import SwiftUI

/// Google-Docs-style inline rename for a note's title: reads as plain header
/// text, grows a subtle outline on hover, and edits in place on click.
/// Enter or clicking away commits through `onRename`; Escape restores the
/// committed title. The committed title stays authoritative — external
/// retitles (tree rename, another panel) overwrite an idle field but never
/// an in-progress edit.
struct NoteTitleRenameField: View {
    let title: String
    let filePath: String
    let foregroundColor: NSColor
    let onRename: (String) -> Void

    @State private var draft: String = ""
    @State private var isHovering = false
    @State private var isFocused = false

    private var placeholder: String {
        String(localized: "note.title.placeholder", defaultValue: "Untitled note")
    }

    private var titleFont: Font {
        .system(size: 12, weight: .semibold)
    }

    private var titleNSFont: NSFont {
        .systemFont(ofSize: 12, weight: .semibold)
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.text")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(Color(nsColor: foregroundColor).opacity(0.58))
                .frame(width: 16, height: 20)

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
                        onCommit: commit,
                        onCancel: { draft = title }
                    )
                }
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(isFocused ? Color.accentColor.opacity(0.65) : Color(nsColor: foregroundColor).opacity(0.22))
                        .frame(height: 1)
                        .opacity(isFocused || isHovering ? 1 : 0)
                }
                .frame(minWidth: 40, minHeight: 20, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .layoutPriority(1)
            .onHover { isHovering = $0 }
            .onAppear { draft = title }
            .onChange(of: title) { _, newValue in
                guard !isFocused else { return }
                draft = newValue
            }
            .help(filePath)
            .accessibilityLabel(String(localized: "note.title.accessibility", defaultValue: "Note title"))
    }

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != title else {
            draft = title
            return
        }
        onRename(trimmed)
        // The rename is async and can fail (index write, invalid slug). Keep the
        // committed title authoritative: fall back to it now, and let the rename's
        // retitle notification deliver the new title through `onChange(of: title)`
        // (Enter already unfocused the field, so the update is not blocked).
        draft = title
    }
}
