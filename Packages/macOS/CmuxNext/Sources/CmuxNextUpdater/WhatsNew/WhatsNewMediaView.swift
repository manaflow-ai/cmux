import AVKit
import CmuxNextDesign
import SwiftUI

/// A screenshot or a short video (no autoplay), rounded, at most 360 points tall.
struct WhatsNewMediaView: View {
    let url: URL
    let isVideo: Bool
    let alt: String

    var body: some View {
        Group {
            if isVideo {
                WhatsNewVideoView(url: url)
            } else {
                // Bundled files load as file URLs off the main thread too.
                AsyncImage(url: url) { image in
                    image.resizable().aspectRatio(contentMode: .fit)
                } placeholder: {
                    Rectangle().fill(Color(nsColor: Palette.hoverFill)).aspectRatio(16 / 10, contentMode: .fit)
                }
            }
        }
        .frame(maxHeight: 360, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color(nsColor: Palette.separator)))
        .accessibilityLabel(alt)
    }
}

/// One player per video view, kept across redraws.
struct WhatsNewVideoView: View {
    @State private var player: AVPlayer

    init(url: URL) {
        _player = State(initialValue: AVPlayer(url: url))
    }

    var body: some View {
        VideoPlayer(player: player)
            .aspectRatio(16 / 10, contentMode: .fit)
    }
}
