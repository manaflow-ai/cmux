import AppKit
import SwiftUI

struct WorkspaceGroupIconPickerView: View {
    private static let pageSize = 180

    let currentSymbol: String?
    let onSelect: (String?) -> Void

    @State private var searchText: String
    @State private var resultLimit = Self.pageSize

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

    private var systemSymbols: [WorkspaceGroupSystemIconCandidate] {
        WorkspaceGroupSystemIconCatalog.shared.matching(query: searchText, limit: resultLimit)
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
    }
}

private struct WorkspaceGroupIconPickerSectionTitle: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
    }
}

private struct WorkspaceGroupIconPickerRow: View, Equatable {
    let icon: RenderableWorkspaceGroupIcon
    let title: String
    let isSelected: Bool
    let action: () -> Void

    nonisolated static func == (lhs: WorkspaceGroupIconPickerRow, rhs: WorkspaceGroupIconPickerRow) -> Bool {
        lhs.icon == rhs.icon &&
            lhs.title == rhs.title &&
            lhs.isSelected == rhs.isSelected
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                WorkspaceGroupIconPreview(icon: icon)
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                Text(title)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 8)
            .frame(height: 30)
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isSelected ? Color.accentColor.opacity(0.16) : Color.clear)
        )
        .help(title)
    }
}

private struct WorkspaceGroupEmojiPickerButton: View, Equatable {
    let emoji: String
    let isSelected: Bool
    let action: () -> Void

    nonisolated static func == (lhs: WorkspaceGroupEmojiPickerButton, rhs: WorkspaceGroupEmojiPickerButton) -> Bool {
        lhs.emoji == rhs.emoji && lhs.isSelected == rhs.isSelected
    }

    var body: some View {
        Button(action: action) {
            Text(emoji)
                .font(.system(size: 18))
                .frame(width: 34, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isSelected ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.08))
        )
        .help(emoji)
    }
}

struct WorkspaceGroupIconPreview: View, Equatable {
    let icon: RenderableWorkspaceGroupIcon

    var body: some View {
        switch icon {
        case .systemSymbol(let symbol):
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
        case .emoji(let emoji):
            Text(emoji)
                .font(.system(size: 14))
        }
    }
}

struct WorkspaceGroupSystemIconCandidate: Identifiable, Equatable {
    let name: String
    let searchTerms: [String]

    var id: String { name }
}

struct WorkspaceGroupSystemIconCatalog {
    static let shared = WorkspaceGroupSystemIconCatalog()

    private let candidates: [WorkspaceGroupSystemIconCandidate]

    init() {
        let names = Self.loadSymbolNames()
        let searchTerms = Self.loadSearchTerms()
        candidates = names.map { name in
            WorkspaceGroupSystemIconCandidate(name: name, searchTerms: searchTerms[name] ?? [])
        }
    }

    @MainActor
    func matching(query rawQuery: String, limit: Int) -> [WorkspaceGroupSystemIconCandidate] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var results: [WorkspaceGroupSystemIconCandidate] = []
        results.reserveCapacity(min(limit, 256))

        for candidate in candidates {
            guard query.isEmpty || candidate.matches(query: query) else { continue }
            guard RenderableSystemSymbol.isRenderable(candidate.name) else { continue }
            results.append(candidate)
            if results.count >= limit {
                break
            }
        }

        return results
    }

    private static func loadSymbolNames() -> [String] {
        let path = "/System/Library/PrivateFrameworks/SFSymbols.framework/Versions/A/Resources/CoreGlyphsPrivate.bundle/Contents/Resources/symbol_order.plist"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let names = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String],
              !names.isEmpty else {
            return fallbackSymbolNames
        }
        return names
    }

    private static func loadSearchTerms() -> [String: [String]] {
        let path = "/System/Library/PrivateFrameworks/SFSymbols.framework/Versions/A/Resources/CoreGlyphsPrivate.bundle/Contents/Resources/symbol_search.plist"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let terms = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: [String]] else {
            return [:]
        }
        return terms
    }

    private static let fallbackSymbolNames = [
        "folder.fill", "folder", "leaf.fill", "sparkles", "terminal.fill", "chevron.right",
        "wrench.and.screwdriver.fill", "gearshape.fill", "hammer.fill", "ladybug.fill",
        "checkmark.circle.fill", "xmark.circle.fill", "exclamationmark.triangle.fill",
        "doc.text.fill", "globe", "lock.fill", "key.fill", "bolt.fill", "flame.fill",
        "star.fill", "heart.fill", "bookmark.fill", "tray.full.fill", "shippingbox.fill"
    ]
}

private extension WorkspaceGroupSystemIconCandidate {
    func matches(query: String) -> Bool {
        name.localizedCaseInsensitiveContains(query) ||
            searchTerms.contains { $0.localizedCaseInsensitiveContains(query) }
    }
}

enum WorkspaceGroupEmojiCatalog {
    private static let emojis = [
        "🚀", "💻", "🧠", "⚙️", "🔥", "✅", "📁", "🧪", "🎯", "✨", "⚡️", "⭐️",
        "🔧", "📌", "📝", "🔍", "🎨", "🧩", "📦", "🌐", "🔒", "💬", "🏁", "📊",
        "🛠️", "🧰", "📣", "💡", "🕹️", "🧵", "🪄", "🧱", "📎", "🗂️", "📚", "🔬"
    ]

    static func matching(query rawQuery: String) -> [String] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return emojis }
        if let emoji = RenderableSystemSymbol.normalizedEmoji(query) {
            return [emoji] + emojis.filter { $0 != emoji }
        }
        return emojis.filter { $0.localizedCaseInsensitiveContains(query) }
    }
}
