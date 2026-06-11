import SwiftUI

struct WorkspaceGroupEmojiPickerButton: View, Equatable {
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
