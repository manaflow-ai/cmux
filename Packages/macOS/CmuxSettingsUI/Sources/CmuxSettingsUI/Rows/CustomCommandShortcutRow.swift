import CmuxSettings
import SwiftUI

/// One Custom Commands row: the command title, a single-stroke shortcut recorder,
/// and a remove button, plus a conflict banner. Receives value snapshots and
/// closures only (no store reference), honoring the list snapshot-boundary rule.
///
/// Custom command shortcuts are single-stroke only (no chords), so the row uses
/// the single-stroke ``ShortcutRecorderView`` initializer.
@MainActor
struct CustomCommandShortcutRow: View {
    let title: String
    let commandId: String
    let binding: StoredShortcut
    let conflict: CustomCommandShortcutConflict?
    let onStroke: (ShortcutStroke) -> Void
    let onRemove: () -> Void
    let onDismissConflict: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(title)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ShortcutRecorderView(
                    placeholder: binding.isUnbound
                        ? String(localized: "shortcut.unbound.displayValue", defaultValue: "None")
                        : shortcutDisplayString(binding, numbered: false),
                    onStroke: onStroke
                )
                .frame(width: 160)
                Button(role: .destructive, action: onRemove) {
                    Image(systemName: "trash")
                        .imageScale(.medium)
                }
                .buttonStyle(.borderless)
                .help(String(localized: "settings.customCommands.remove.help", defaultValue: "Remove this custom shortcut"))
                .accessibilityIdentifier("CustomCommandShortcutRemoveButton")
            }
            if let conflict {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.red)
                    Text(conflictMessage(conflict))
                        .font(.caption).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(String(localized: "shortcut.recorder.undo", defaultValue: "Undo"), action: onDismissConflict)
                        .buttonStyle(.link).font(.caption)
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background { RoundedRectangle(cornerRadius: 6).fill(Color.red.opacity(0.12)) }
                .overlay { RoundedRectangle(cornerRadius: 6).stroke(Color.red.opacity(0.35), lineWidth: 1) }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private func conflictMessage(_ conflict: CustomCommandShortcutConflict) -> String {
        switch conflict {
        case .action:
            return String(localized: "settings.customCommands.conflict.action", defaultValue: "This shortcut is already used by a built-in shortcut.")
        case .command:
            return String(localized: "settings.customCommands.conflict.command", defaultValue: "This shortcut is already used by another command.")
        }
    }
}
