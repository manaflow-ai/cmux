import CmuxNextDesign
import SwiftUI

/// One dropdown row: a value snapshot and a closure (no model reference below the list).
struct NativeNewTabRowView: View, Equatable {
    let content: NativeNewTabRowContent
    let selected: Bool
    let activate: @MainActor () -> Void

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.content == rhs.content && lhs.selected == rhs.selected }

    var body: some View {
        Button(action: activate) {
            HStack(spacing: Metrics.space3) {
                Image(systemName: content.symbol).frame(width: 18).foregroundStyle(.secondary)
                Text(content.title).font(Font(Typography.body)).lineLimit(1)
                if let detail = content.detail {
                    Text(detail).font(Font(Typography.caption)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: Metrics.space3)
                if let hint = content.hint { Text(hint).font(Font(Typography.shortcut)).foregroundStyle(.tertiary) }
            }
            .padding(.horizontal, Metrics.space4)
            .frame(height: 30)
            .contentShape(Rectangle())
            .background(selected ? Color(nsColor: Palette.accent).opacity(0.18) : Color.clear)
        }
        .buttonStyle(.plain)
    }
}
