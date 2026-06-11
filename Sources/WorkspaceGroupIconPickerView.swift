import AppKit
import SwiftUI

struct WorkspaceGroupIconPickerView: View {
    private static let pageSize = 120

    let currentSymbol: String?
    let onSelect: (String?) -> Void

    @State private var searchText = ""
    @State private var visibleEmojiCount = pageSize
    @FocusState private var searchFieldFocused: Bool

    init(currentSymbol: String?, onSelect: @escaping (String?) -> Void) {
        self.currentSymbol = currentSymbol
        self.onSelect = onSelect
    }

    private var selectedIcon: String? {
        RenderableSystemSymbol.normalizedWorkspaceGroupIcon(currentSymbol)
    }

    private var currentIcon: RenderableWorkspaceGroupIcon? {
        guard let selectedIcon else { return nil }
        if let emoji = RenderableSystemSymbol.normalizedEmoji(selectedIcon) {
            return .emoji(emoji)
        }
        return .systemSymbol(selectedIcon)
    }

    private var typedEmoji: String? {
        RenderableSystemSymbol.normalizedEmoji(searchText)
    }

    private var typedSystemSymbol: String? {
        guard typedEmoji == nil else { return nil }
        return RenderableSystemSymbol.normalizedWorkspaceGroupIcon(searchText)
    }

    private var matchedEmoji: [String] {
        WorkspaceGroupEmojiCatalog.search(searchText)
    }

    var body: some View {
        // The baked dataset makes search a fast in-memory scan; `visibleEmoji` caps how many
        // cells are ever instantiated so view materialization stays bounded.
        let matched = matchedEmoji
        let visibleEmoji = Array(matched.prefix(visibleEmojiCount))

        VStack(spacing: 10) {
            TextField(
                String(localized: "workspaceGroup.icon.search.placeholder", defaultValue: "Search emoji"),
                text: $searchText
            )
            .textFieldStyle(.roundedBorder)
            .frame(height: 24)
            .focused($searchFieldFocused)
            .onChange(of: searchText) { _, _ in
                visibleEmojiCount = Self.pageSize
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if let selectedIcon,
                       let currentIcon {
                        WorkspaceGroupIconPickerSectionTitle(
                            title: String(localized: "workspaceGroup.icon.section.current", defaultValue: "Current")
                        )
                        Button {
                            onSelect(selectedIcon)
                        } label: {
                            HStack(spacing: 8) {
                                WorkspaceGroupIconPreview(icon: currentIcon)
                                    .frame(width: 22, height: 22)
                                Text(selectedIcon)
                                    .font(.system(size: 12))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Spacer()
                            }
                            .padding(.horizontal, 8)
                            .frame(height: 32)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(Color.accentColor.opacity(0.16))
                        )
                        .help(selectedIcon)
                    }

                    if let typedSystemSymbol {
                        WorkspaceGroupIconPickerSectionTitle(
                            title: String(localized: "workspaceGroup.icon.section.symbols", defaultValue: "Symbols")
                        )
                        Button {
                            onSelect(typedSystemSymbol)
                        } label: {
                            HStack(spacing: 8) {
                                WorkspaceGroupIconPreview(icon: .systemSymbol(typedSystemSymbol))
                                    .frame(width: 22, height: 22)
                                Text(typedSystemSymbol)
                                    .font(.system(size: 12))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Spacer()
                            }
                            .padding(.horizontal, 8)
                            .frame(height: 32)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(selectedIcon == typedSystemSymbol ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.08))
                        )
                        .help(typedSystemSymbol)
                    }

                    if !visibleEmoji.isEmpty {
                        WorkspaceGroupIconPickerSectionTitle(
                            title: String(localized: "workspaceGroup.icon.section.emoji", defaultValue: "Emoji")
                        )
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 34, maximum: 42), spacing: 6)],
                            alignment: .leading,
                            spacing: 6
                        ) {
                            ForEach(visibleEmoji, id: \.self) { emoji in
                                WorkspaceGroupEmojiPickerButton(
                                    emoji: emoji,
                                    isSelected: selectedIcon == emoji
                                ) {
                                    onSelect(emoji)
                                }
                                .onAppear {
                                    guard emoji == visibleEmoji.last,
                                          visibleEmoji.count < matched.count else { return }
                                    visibleEmojiCount += Self.pageSize
                                }
                            }
                        }
                    } else if typedEmoji == nil && typedSystemSymbol == nil {
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
        .onAppear {
            searchFieldFocused = true
        }
    }
}
