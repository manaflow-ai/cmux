import CmuxFoundation
import SwiftUI

/// One dropdown row: kind icon, highlighted title, and the workspace context /
/// kind label. Holds only value data plus its select closure, never a store.
struct SidebarTabSearchResultRow: View {
    let result: SidebarTabSearchResult
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .cmuxFont(size: 11, weight: .medium)
                    .foregroundColor(.secondary)
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 1) {
                    highlightedTitle
                        .cmuxFont(size: 12)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !result.subtitle.isEmpty {
                        Text(result.subtitle)
                            .cmuxFont(size: 10)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 4)
                if let kindLabel = result.kindLabel, result.kind == .tab {
                    Text(kindLabel)
                        .cmuxFont(size: 9, weight: .medium)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
                    .padding(.horizontal, 4)
            )
        }
        .buttonStyle(.plain)
    }

    private var iconName: String {
        result.kind == .workspace ? "rectangle.stack" : "rectangle"
    }

    /// Bolds/colors the title characters the fuzzy matcher matched, mirroring
    /// `ContentView.commandPaletteHighlightedTitleText`.
    private var highlightedTitle: Text {
        guard !result.titleMatchIndices.isEmpty else {
            return Text(result.title).foregroundColor(.primary)
        }
        let chars = Array(result.title)
        var index = 0
        var text = Text("")
        while index < chars.count {
            let isMatched = result.titleMatchIndices.contains(index)
            var end = index + 1
            while end < chars.count, result.titleMatchIndices.contains(end) == isMatched {
                end += 1
            }
            let segment = String(chars[index..<end])
            text = text + Text(segment).foregroundColor(isMatched ? .accentColor : .primary)
            index = end
        }
        return text
    }
}
