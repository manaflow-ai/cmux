import CmuxNextIcons
import SwiftUI

/// A small floating notice (a refusal, a late answer). Dismissed by the user.
struct FeedToast: View {
    let text: String
    let dismiss: () -> Void
    @Environment(\.feedColors) private var colors

    var body: some View {
        HStack(spacing: 8) {
            Text(text).font(.system(size: 11.5)).foregroundStyle(colors.primary).lineLimit(2)
            Button(action: dismiss) {
                Icon(.actionClose, size: .iconFloor).foregroundStyle(colors.tertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(colors.elevated)
                .shadow(color: colors.shadow, radius: 8, y: 2)
        )
    }
}

/// Nothing to show: one quiet line, centered.
struct FeedEmptyState: View {
    let text: String
    @Environment(\.feedColors) private var colors

    var body: some View {
        VStack(spacing: 8) {
            Icon(.inboxEmpty, size: 20).foregroundStyle(colors.tertiary)
            Text(text).font(.system(size: 12)).foregroundStyle(colors.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

/// A hairline that disappears under `appearance.borders = none`.
struct FeedHairline: View {
    var vertical = false
    @Environment(\.feedColors) private var colors

    var body: some View {
        if colors.borders {
            Rectangle().fill(colors.separator).frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
        } else {
            Color.clear.frame(width: vertical ? 6 : nil, height: vertical ? nil : 6)
        }
    }
}
