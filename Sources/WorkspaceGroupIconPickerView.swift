import AppKit
import SwiftUI

struct WorkspaceGroupIconPickerView: View {
    private static let pageSize = 96

    let currentSymbol: String?
    let onSelect: (String?) -> Void

    @State private var searchText: String
    @State private var emojiLimit = Self.pageSize

    init(currentSymbol: String?, onSelect: @escaping (String?) -> Void) {
        self.currentSymbol = currentSymbol
        self.onSelect = onSelect
        _searchText = State(initialValue: RenderableSystemSymbol.normalizedEmoji(currentSymbol ?? "") ?? "")
    }

    private var selectedIcon: String? {
        RenderableSystemSymbol.normalizedWorkspaceGroupIcon(currentSymbol)
    }

    private var typedEmoji: String? {
        RenderableSystemSymbol.normalizedEmoji(searchText)
    }

    private var emojiSuggestions: [String] {
        emojiMatches.emojis
    }

    private var emojiMatches: (emojis: [String], hasMore: Bool) {
        WorkspaceGroupEmojiCatalog.matching(query: searchText, limit: emojiLimit)
    }

    var body: some View {
        VStack(spacing: 10) {
            TextField(
                String(localized: "workspaceGroup.icon.search.placeholder", defaultValue: "Search emoji"),
                text: $searchText
            )
            .textFieldStyle(.roundedBorder)
            .frame(height: 24)
            .onChange(of: searchText) { _, _ in
                emojiLimit = Self.pageSize
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if let typedEmoji {
                        WorkspaceGroupIconPickerSectionTitle(
                            title: String(localized: "workspaceGroup.icon.section.current", defaultValue: "Current")
                        )
                        WorkspaceGroupEmojiPickerButton(
                            emoji: typedEmoji,
                            isSelected: selectedIcon == typedEmoji
                        ) {
                            onSelect(typedEmoji)
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
                                .onAppear {
                                    guard emojiMatches.hasMore,
                                          emoji == emojiSuggestions.last else { return }
                                    emojiLimit += Self.pageSize
                                }
                            }
                        }
                    } else if typedEmoji == nil {
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
    }
}
