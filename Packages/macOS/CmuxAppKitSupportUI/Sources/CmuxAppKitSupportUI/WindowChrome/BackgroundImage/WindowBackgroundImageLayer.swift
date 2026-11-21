public import AppKit
public import CmuxFoundation
public import SwiftUI

/// Paints the window background image behind every other window layer.
///
/// Place it at the bottom of the window's root `ZStack`, under the
/// ``WindowBackdropLayer`` for ``WindowBackdropRole/windowRoot``. It fills the
/// window with the opaque terminal background color, then draws the image on
/// top at the chosen opacity, so text over it keeps most of the theme's
/// contrast. While the image decodes, or when the file cannot be read, only
/// the color shows.
///
/// It draws nothing when the snapshot has no
/// ``WindowAppearanceSnapshot/backgroundImage``.
public struct WindowBackgroundImageLayer: View {
    private let settings: WindowBackgroundImageSettings?
    private let baseColor: NSColor
    private let homeDirectory: URL
    private let decoder: WindowBackgroundImageDecoder

    @State private var loaded: LoadedImage?

    /// Creates the layer for a resolved window appearance.
    ///
    /// - Parameters:
    ///   - snapshot: The window appearance; its background image and terminal
    ///     background color are drawn.
    ///   - homeDirectory: The directory a `~/` image path expands to.
    ///   - decoder: Decodes the image file off the main actor.
    public init(
        snapshot: WindowAppearanceSnapshot,
        homeDirectory: URL,
        decoder: WindowBackgroundImageDecoder = WindowBackgroundImageDecoder()
    ) {
        self.settings = snapshot.backgroundImage
        self.baseColor = snapshot.terminalBackgroundColor.withAlphaComponent(1)
        self.homeDirectory = homeDirectory
        self.decoder = decoder
    }

    /// Rendered layer body.
    public var body: some View {
        if let settings {
            let url = settings.resolvedFileURL(homeDirectory: homeDirectory)
            ZStack {
                Color(nsColor: baseColor)
                if let loaded, loaded.url == url {
                    image(loaded.image, fit: settings.fit)
                        .opacity(settings.opacity)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .task(id: url) {
                await load(url)
            }
        }
    }

    @ViewBuilder
    private func image(_ image: WindowBackgroundImage, fit: WindowBackgroundImageFit) -> some View {
        let picture = Image(decorative: image.cgImage, scale: 1)
            .resizable()
            .interpolation(.high)
        // A clear view takes the window's size; the overlay sizes the picture
        // to it, and clipping crops a covering picture's overflow.
        Color.clear
            .overlay {
                switch fit {
                case .cover:
                    picture.aspectRatio(contentMode: .fill)
                case .contain:
                    picture.aspectRatio(contentMode: .fit)
                case .stretch:
                    picture
                }
            }
            .clipped()
    }

    private func load(_ url: URL?) async {
        guard let url else {
            loaded = nil
            return
        }
        if loaded?.url == url { return }
        let decoder = decoder
        let image = await Task.detached(priority: .utility) {
            decoder.decode(contentsOf: url)
        }.value
        // A newer path replaced this one while the file was decoding.
        guard !Task.isCancelled else { return }
        loaded = image.map { LoadedImage(url: url, image: $0) }
    }
}

/// An image together with the file it came from, so a stale decode is never
/// drawn for a newer path.
private struct LoadedImage {
    let url: URL
    let image: WindowBackgroundImage
}
