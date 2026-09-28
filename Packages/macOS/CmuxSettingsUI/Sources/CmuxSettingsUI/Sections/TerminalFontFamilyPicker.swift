import AppKit
import SwiftUI

/// A searchable list of installed monospaced fonts, each drawn in its own
/// face, for the Font card's font row. Hovering a font previews it in the
/// card; clicking one applies it. `nil` stands for Ghostty's built-in font, so
/// ``hoveredFamily`` is `.some(nil)` over that row and `nil` over none.
struct TerminalFontFamilyPicker: View {
    let families: [String]
    let selection: String?
    @Binding var hoveredFamily: String??
    let onSelect: (String?) -> Void

    @State private var query = ""

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var filteredFamilies: [String] {
        let query = trimmedQuery
        guard !query.isEmpty else { return families }
        return families.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField(
                String(localized: "settings.terminal.font.search", defaultValue: "Search fonts"),
                text: $query
            )
            .textFieldStyle(.roundedBorder)
            .padding(10)
            .accessibilityIdentifier("SettingsTerminalFontSearchField")
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if trimmedQuery.isEmpty {
                        row(family: nil)
                    }
                    ForEach(filteredFamilies, id: \.self) { family in
                        row(family: family)
                    }
                    if filteredFamilies.isEmpty {
                        Text(String(localized: "settings.terminal.font.noMatches", defaultValue: "No installed monospaced fonts match."))
                            .cmuxFont(.caption)
                            .foregroundStyle(.secondary)
                            .padding(14)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .frame(width: 340, height: 400)
        .onDisappear { hoveredFamily = nil }
    }

    private func row(family: String?) -> some View {
        let isSelected = family == selection
        let title = family ?? String.localizedStringWithFormat(
            String(localized: "settings.terminal.font.builtIn", defaultValue: "Default (%@)"),
            NSFont.ghosttyBuiltInFamily
        )
        return Button {
            onSelect(family)
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: title)
                        .font(Font(NSFont.terminalPreview(family: family, size: 14)))
                        .lineLimit(1)
                    Text(verbatim: "0O 1lI {} => != ->")
                        .font(Font(NSFont.terminalPreview(family: family, size: 11)))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hoveredFamily == .some(family) ? Color.accentColor.opacity(0.12) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .onHover { inside in
            if inside {
                hoveredFamily = .some(family)
            } else if hoveredFamily == .some(family) {
                hoveredFamily = nil
            }
        }
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
