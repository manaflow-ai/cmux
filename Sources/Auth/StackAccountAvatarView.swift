import AppKit
import SwiftUI

/// Displays the Stack profile image with an initial-based fallback.
struct StackAccountAvatarView: View {
    let avatarURL: URL?
    let displayName: String
    let email: String
    let size: CGFloat

    var body: some View {
        Group {
            if let avatarURL {
                AsyncImage(url: avatarURL) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        fallback
                    }
                }
            } else {
                fallback
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
        .accessibilityHidden(true)
    }

    private var fallback: some View {
        ZStack {
            Circle().fill(Color.accentColor.opacity(0.18))
            if let initial {
                Text(verbatim: initial)
                    .cmuxFont(size: max(8, size * 0.4), weight: .semibold)
                    .foregroundStyle(Color.accentColor)
            } else {
                CmuxSystemSymbolImage(
                    systemName: "person.fill",
                    pointSize: max(8, size * 0.45),
                    weight: .medium
                )
                .foregroundStyle(Color.accentColor)
            }
        }
    }

    private var initial: String? {
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = trimmedName.isEmpty ? email : trimmedName
        return source.first.map { String($0).uppercased() }
    }
}
