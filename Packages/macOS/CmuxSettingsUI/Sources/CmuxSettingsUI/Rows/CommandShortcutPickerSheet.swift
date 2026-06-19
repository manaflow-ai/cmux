import CmuxCommandPalette
import CmuxSettings
import SwiftUI

/// A searchable list of commands the user can bind a custom shortcut to.
@MainActor
struct CommandShortcutPickerSheet: View {
    let commands: [BindableCommandDescriptor]
    let onSelect: (BindableCommandDescriptor) -> Void
    let onCancel: () -> Void

    @State private var query: String = ""

    /// The same fuzzy ranking engine the Command Palette uses, so a query like
    /// "open X" matches "Open Workspace in X" (non-contiguous tokens), not just
    /// exact substrings. Rebuilt per access — cheap for this short list.
    private var searchEngine: CommandPaletteSearchEngine<BindableCommandDescriptor> {
        CommandPaletteSearchEngine(
            entries: commands.enumerated().map { index, descriptor in
                CommandPaletteSearchCorpusEntry(
                    payload: descriptor,
                    rank: index,
                    title: descriptor.title,
                    searchableTexts: [descriptor.title, descriptor.id]
                )
            }
        )
    }

    private var filtered: [BindableCommandDescriptor] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return commands }
        return searchEngine
            .search(query: trimmed, historyBoost: { _, _ in 0 })
            .map(\.payload)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(String(localized: "settings.customCommands.picker.title", defaultValue: "Choose a command"))
                    .font(.headline)
                Spacer()
                Button(String(localized: "settings.customCommands.picker.cancel", defaultValue: "Cancel"), action: onCancel)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
            TextField(
                String(localized: "settings.customCommands.picker.search", defaultValue: "Search commands…"),
                text: $query
            )
            .textFieldStyle(.roundedBorder)
            .padding(.horizontal, 12)
            .accessibilityIdentifier("CustomCommandPickerSearchField")
            List(filtered) { descriptor in
                Button { onSelect(descriptor) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(descriptor.title)
                        Text(descriptor.id).font(.caption).foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .frame(minWidth: 360, minHeight: 320)
        }
        .frame(width: 420, height: 420)
    }
}
