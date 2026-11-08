#if os(iOS)
import AVKit
import SwiftUI

/// Hosts AVKit's system playback controls for a local movie or audio artifact.
struct ChatArtifactMediaView: UIViewControllerRepresentable {
    let fileURL: URL

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = AVPlayer(url: fileURL)
        controller.videoGravity = .resizeAspect
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        let currentURL = (controller.player?.currentItem?.asset as? AVURLAsset)?.url
        if currentURL != fileURL {
            controller.player?.pause()
            controller.player = AVPlayer(url: fileURL)
        }
    }

    static func dismantleUIViewController(
        _ controller: AVPlayerViewController,
        coordinator: Void
    ) {
        controller.player?.pause()
        controller.player = nil
    }
}
#endif
