import CmuxNextIcons
import SwiftUI

/// Nothing to show: one quiet line, centered.
struct FeedEmptyState: View {
    let text: String
    @Environment(\.feedColors) private var colors

    var body: some View {
        VStack(spacing: 8) {
            // A pack drawing inks about two thirds of its box; 32 matches the 20 pt tray it replaced.
            Icon(.inboxEmpty, size: 32).foregroundStyle(colors.tertiary)
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
