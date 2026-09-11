import AppKit
import CmuxAppKitSupportUI
import SwiftUI

/// Displays the Stack profile image with an initial-based fallback.
///
/// The picture is drawn by the AppKit-hosted icon renderer with the same
/// contract as the Vault agent icons: the decoded (already circular) bitmap is
/// the primary source and a tinted person symbol is the fallback for a
/// transient blank draw. No SwiftUI raster image, mask, or clip shape touches
/// the hosted view; those go blank after a while on Intel Macs running
/// macOS 15.
struct StackAccountAvatarView: View {
    let avatarURL: URL?
    let displayName: String
    let email: String
    let size: CGFloat
    var loadingSystemName: String? = nil

    @State private var loadedAvatar: LoadedAvatar?

    /// Symbol drawn when the decoded picture renders blank, mirroring
    /// `SessionIndexAgentIconImage`.
    static let fallbackSymbolName = "person.crop.circle.fill"

    /// Builds the renderer request for a decoded profile picture.
    static func hostedRequest(image: NSImage, size: CGFloat) -> CmuxResolvedIconRequest {
        CmuxResolvedIconRequest(
            source: .image(image),
            size: NSSize(width: size, height: size),
            fallbackSource: .systemSymbol(
                name: fallbackSymbolName,
                accessibilityDescription: nil
            ),
            fallbackTintColor: .secondaryLabelColor
        )
    }

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
                        CmuxResolvedIconImage(request: Self.hostedRequest(image: image, size: size))
                            .frame(width: size, height: size)
                    } else {
                        fallback
                    }
                } else if let loadingSystemName {
                    CmuxSystemSymbolImage(
                        systemName: loadingSystemName,
                        pointSize: size,
                        weight: .regular,
                        tint: Color(nsColor: .secondaryLabelColor)
                    )
                } else {
                    fallback
                }
            } else {
                fallback
            }
        }
        .frame(width: size, height: size)
        // The picture is circular inside its bitmap and the fallbacks draw a
        // `Circle()` themselves, so no `clipShape` wraps the hosted view.
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
                    weight: .medium,
                    tint: fallbackForegroundColor
                )
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
