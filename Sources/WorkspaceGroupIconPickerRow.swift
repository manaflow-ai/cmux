import SwiftUI

struct WorkspaceGroupIconPickerRow: View, Equatable {
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
