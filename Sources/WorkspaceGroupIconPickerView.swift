import AppKit
import SwiftUI

struct WorkspaceGroupIconPickerView: View {
    private static let pageSize = 180

    let currentSymbol: String?
    let onSelect: (String?) -> Void

    @State private var searchText: String
    @State private var resultLimit = Self.pageSize
    @State private var systemCatalog = WorkspaceGroupSystemIconCatalog.fallback

    init(currentSymbol: String?, onSelect: @escaping (String?) -> Void) {
        self.currentSymbol = currentSymbol
        self.onSelect = onSelect
        _searchText = State(initialValue: currentSymbol ?? "")
    }

    private var selectedIcon: String? {
        RenderableSystemSymbol.normalizedWorkspaceGroupIcon(currentSymbol)
    }

    private var typedIcon: RenderableWorkspaceGroupIcon? {
        guard let normalized = RenderableSystemSymbol.normalizedWorkspaceGroupIcon(searchText) else { return nil }
        if let emoji = RenderableSystemSymbol.normalizedEmoji(normalized) {
            return .emoji(emoji)
        }
        return .systemSymbol(normalized)
    }

    private var emojiSuggestions: [String] {
        WorkspaceGroupEmojiCatalog.matching(query: searchText)
    }

    private var systemSymbols: [WorkspaceGroupSystemIconCatalog.Candidate] {
        systemCatalog.matching(query: searchText, limit: resultLimit)
    }

    var body: some View {
        VStack(spacing: 10) {
            TextField(
                String(localized: "workspaceGroup.icon.search.placeholder", defaultValue: "Search icons"),
                text: $searchText
            )
            .textFieldStyle(.roundedBorder)
            .frame(height: 24)
            .onChange(of: searchText) { _, _ in
                resultLimit = Self.pageSize
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if let typedIcon {
                        WorkspaceGroupIconPickerSectionTitle(
                            title: String(localized: "workspaceGroup.icon.section.current", defaultValue: "Current")
                        )
                        WorkspaceGroupIconPickerRow(
                            icon: typedIcon,
                            title: typedIcon.rawValue,
                            isSelected: selectedIcon == typedIcon.rawValue
                        ) {
                            onSelect(typedIcon.rawValue)
                        }
                    }

                    if !emojiSuggestions.isEmpty {
                        WorkspaceGroupIconPickerSectionTitle(
                            title: String(localized: "workspaceGroup.icon.section.emoji", defaultValue: "Emoji")
                        )
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 34, maximum: 42), spacing: 6)],
                            alignment: .leading,
                            spacing: 6
                        ) {
                            ForEach(emojiSuggestions, id: \.self) { emoji in
                                WorkspaceGroupEmojiPickerButton(
                                    emoji: emoji,
                                    isSelected: selectedIcon == emoji
                                ) {
                                    onSelect(emoji)
                                }
                            }
                        }
                    }

                    if !systemSymbols.isEmpty {
                        WorkspaceGroupIconPickerSectionTitle(
                            title: String(localized: "workspaceGroup.icon.section.symbols", defaultValue: "Symbols")
                        )
                        ForEach(systemSymbols) { candidate in
                            WorkspaceGroupIconPickerRow(
                                icon: .systemSymbol(candidate.name),
                                title: candidate.name,
                                isSelected: selectedIcon == candidate.name
                            ) {
                                onSelect(candidate.name)
                            }
                            .onAppear {
                                guard candidate.id == systemSymbols.last?.id else { return }
                                resultLimit += Self.pageSize
                            }
                        }
                    } else if typedIcon == nil && emojiSuggestions.isEmpty {
                        Text(String(localized: "workspaceGroup.icon.noResults", defaultValue: "No icons found"))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 72)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(width: 318, height: 306)

            HStack {
                Button(String(localized: "workspaceGroup.icon.clear", defaultValue: "Clear Icon")) {
                    onSelect(nil)
                }
                Spacer()
            }
        }
        .padding(12)
        .frame(width: 344, height: 394)
        .task {
            systemCatalog = await WorkspaceGroupSystemIconCatalogStore.shared.catalog()
        }
    }
}
