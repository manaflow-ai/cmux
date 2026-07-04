import CmuxFoundation
import SwiftUI

/// Red inline validation banner with an Undo affordance, matching the per-action
/// recorder rows. Factored out so the bound-command rows and any future
/// command-shortcut surface render an identical banner.
@MainActor
struct ShortcutValidationBanner: View {
    let message: String
    let onUndo: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .cmuxFont(.caption)
                .foregroundStyle(.red)
            Text(message)
                .cmuxFont(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
            Button(String(localized: "shortcut.recorder.undo", defaultValue: "Undo")) {
                onUndo()
            }
            .buttonStyle(.link)
            .cmuxFont(.caption)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 6).fill(Color.red.opacity(0.12))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 6).stroke(Color.red.opacity(0.35), lineWidth: 1)
        }
        .accessibilityIdentifier("ShortcutRecorderValidationMessage")
    }
}
