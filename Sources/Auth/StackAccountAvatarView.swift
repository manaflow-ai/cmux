import AppKit
import SwiftUI

enum StackAccountAvatarLoadingPlaceholder {
    case identity
    case systemIcon(name: String)
}

enum StackAccountAvatarIdentityFallbackStyle {
    case accent
    case neutral
}

/// Displays the Stack profile image with an initial-based fallback.
struct StackAccountAvatarView: View {
    let avatarURL: URL?
    let displayName: String
    let email: String
    let size: CGFloat
    let loadingPlaceholder: StackAccountAvatarLoadingPlaceholder
    let identityFallbackStyle: StackAccountAvatarIdentityFallbackStyle

    init(
        avatarURL: URL?,
        displayName: String,
        email: String,
        size: CGFloat,
        loadingPlaceholder: StackAccountAvatarLoadingPlaceholder = .identity,
        identityFallbackStyle: StackAccountAvatarIdentityFallbackStyle = .accent
    ) {
        self.avatarURL = avatarURL
        self.displayName = displayName
        self.email = email
        self.size = size
        self.loadingPlaceholder = loadingPlaceholder
        self.identityFallbackStyle = identityFallbackStyle
    }

    var body: some View {
        Group {
            if let avatarURL {
                AsyncImage(url: avatarURL) { phase in
                    if let image = phase.image {
                        framedAvatar(image.resizable().scaledToFill())
                    } else if phase.error != nil {
                        framedAvatar(fallback)
                    } else {
                        loadingView
                    }
                }
            } else {
                framedAvatar(fallback)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var loadingView: some View {
        switch loadingPlaceholder {
        case .identity:
            framedAvatar(fallback)
        case .systemIcon(let name):
            CmuxSystemSymbolImage(
                systemName: name,
                pointSize: size,
                weight: .regular
            )
            .foregroundStyle(Color(nsColor: .secondaryLabelColor))
        }
    }

    private func framedAvatar(_ content: some View) -> some View {
        content
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay(Circle().stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
    }

    private var fallback: some View {
        ZStack {
            Circle().fill(fallbackForegroundColor.opacity(0.18))
            if let initial {
                Text(verbatim: initial)
                    .cmuxFont(size: max(8, size * 0.4), weight: .semibold)
                    .foregroundStyle(fallbackForegroundColor)
            } else {
                CmuxSystemSymbolImage(
                    systemName: "person.fill",
                    pointSize: max(8, size * 0.45),
                    weight: .medium
                )
                .foregroundStyle(fallbackForegroundColor)
            }
        }
    }

    private var fallbackForegroundColor: Color {
        switch identityFallbackStyle {
        case .accent:
            Color.accentColor
        case .neutral:
            Color(nsColor: .secondaryLabelColor)
        }
    }

    private var initial: String? {
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = trimmedName.isEmpty ? email : trimmedName
        return source.first.map { String($0).uppercased() }
    }
}
