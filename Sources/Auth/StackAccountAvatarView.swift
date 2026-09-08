import AppKit
import CmuxAppKitSupportUI
import SwiftUI

/// Displays the Stack profile image with an initial-based fallback.
struct StackAccountAvatarView: View {
    let avatarURL: URL?
    let displayName: String
    let email: String
    let size: CGFloat
    var loadingSystemName: String? = nil

    @State private var loadedAvatar: LoadedAvatar?

    /// The last completed load, keyed by URL so a changed URL shows the
    /// loading state again instead of a stale picture.
    private struct LoadedAvatar {
        let url: URL
        let image: NSImage?
    }

    var body: some View {
        Group {
            if let avatarURL {
                if let loadedAvatar, loadedAvatar.url == avatarURL {
                    if let image = loadedAvatar.image {
                        // The hosted AppKit renderer draws the picture; SwiftUI
                        // raster images are blank on Intel Macs running macOS 15.
                        CmuxResolvedIconImage(request: CmuxResolvedIconRequest(
                            source: .image(image),
                            size: NSSize(width: size, height: size)
                        ))
                    } else {
                        fallback
                    }
                } else if let loadingSystemName {
                    CmuxSystemSymbolImage(
                        systemName: loadingSystemName,
                        pointSize: size,
                        weight: .regular
                    )
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                } else {
                    fallback
                }
            } else {
                fallback
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
        .accessibilityHidden(true)
        .task(id: avatarURL) {
            guard let avatarURL else { return }
            let image = await StackAccountAvatarImageLoader.load(from: avatarURL, pointSize: size)
            guard !Task.isCancelled else { return }
            loadedAvatar = LoadedAvatar(url: avatarURL, image: image)
        }
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
        loadingSystemName == nil ? Color.accentColor : Color(nsColor: .secondaryLabelColor)
    }

    private var initial: String? {
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = trimmedName.isEmpty ? email : trimmedName
        return source.first.map { String($0).uppercased() }
    }
}
