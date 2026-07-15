import CmuxFoundation
import CmuxSettings
import SwiftUI

struct SavedTerminalCommandRow: View {
    let command: SavedTerminalCommand
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(command.name).cmuxFont(.body, weight: .medium)
                Text(command.command.replacingOccurrences(of: "\n", with: " ↵ "))
                    .cmuxFont(.caption, monospacedDigit: true)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button(String(localized: "settings.common.edit", defaultValue: "Edit"), action: onEdit)
                .buttonStyle(.borderless)
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(String(
                localized: "settings.terminal.savedCommands.delete",
                defaultValue: "Delete"
            ))
        }
    }
}
