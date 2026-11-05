#if os(iOS)
import CmuxMobileDesign
import CmuxMobileModel
import SwiftUI

private let theme = CmuxMobileTheme.standard

/// Set Icon…: every SF Symbol this iPhone draws (the Mac's icon picker has every symbol its Mac
/// draws), searchable by name and keyword, or one emoji. A tap sets the icon on the Mac
/// (`set-workspace-metadata {icon}`) and closes the picker.
struct WorkspaceIconPicker: View {
    let workspace: Workspace
    let choose: (String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var catalog: WorkspaceSymbolCatalog?
    @State private var query = ""
    @State private var emoji = ""

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Set Icon")
                .navigationBarTitleDisplayMode(.inline)
                .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search symbols")
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    if workspace.icon != nil {
                        ToolbarItem(placement: .destructiveAction) {
                            Button("Remove Icon", role: .destructive) { pick(nil) }
                                .accessibilityIdentifier("iconPicker.remove")
                        }
                    }
                }
        }
        .task {
            guard catalog == nil else { return }
            catalog = await WorkspaceSymbolCatalog.load()
        }
        .accessibilityIdentifier("iconPicker")
    }

    @ViewBuilder private var content: some View {
        if let catalog {
            let names = catalog.search(query)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if query.isEmpty { emojiRow }
                    if catalog.names.isEmpty {
                        ContentUnavailableView("No Symbols", systemImage: "questionmark.square.dashed",
                                               description: Text("This iPhone didn't list its symbols. Type an emoji above."))
                    } else if names.isEmpty {
                        ContentUnavailableView.search(text: query)
                    } else {
                        Text(names.count == 1 ? "1 symbol" : "\(names.count) symbols")
                            .font(theme.type.meta)
                            .foregroundStyle(theme.colors.label2.color)
                            .padding(.horizontal, 20)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 52), spacing: 8)], spacing: 8) {
                            ForEach(names, id: \.self) { name in cell(name) }
                        }
                        .padding(.horizontal, 16)
                    }
                }
                .padding(.vertical, 12)
            }
            .background(theme.colors.bg.color.ignoresSafeArea())
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(theme.colors.bg.color.ignoresSafeArea())
        }
    }

    /// One emoji instead of a symbol, as the Mac's Emoji tab.
    private var emojiRow: some View {
        HStack(spacing: 12) {
            TextField("One emoji", text: $emoji)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("iconPicker.emoji")
            Button("Use Emoji") {
                if let value = WorkspaceIcon.emoji(emoji) { pick(value) }
            }
            .disabled(WorkspaceIcon.emoji(emoji) == nil)
        }
        .padding(.horizontal, 20)
    }

    private func cell(_ name: String) -> some View {
        let chosen = workspace.icon == name
        return Button {
            pick(name)
        } label: {
            Image(systemName: name)
                .font(.title2)
                .frame(width: 52, height: 52)
                .foregroundStyle(theme.colors.label.color)
                .background(theme.colors.label.color.opacity(chosen ? 0.18 : 0.06), in: .rect(cornerRadius: 10, style: .continuous))
                .overlay {
                    if chosen {
                        RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(theme.colors.label.color.opacity(0.6), lineWidth: 2)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .accessibilityAddTraits(chosen ? .isSelected : [])
        .accessibilityIdentifier("iconPicker.symbol.\(name)")
    }

    private func pick(_ icon: String?) {
        choose(icon)
        dismiss()
    }
}
#endif
