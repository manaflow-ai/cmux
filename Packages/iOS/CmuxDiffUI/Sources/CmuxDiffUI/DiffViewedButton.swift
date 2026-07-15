import SwiftUI

struct DiffViewedButton: View {
    let isViewed: Bool
    let action: @MainActor () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isViewed ? "checkmark.square.fill" : "square")
                .foregroundStyle(isViewed ? Color.accentColor : .secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            DiffLocalized().string(
                isViewed ? "diff.viewed.markUnviewed" : "diff.viewed.markViewed",
                defaultValue: isViewed ? "Mark as unviewed" : "Mark as viewed"
            )
        )
    }
}
