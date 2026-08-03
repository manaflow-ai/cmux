#if os(iOS)
import AVKit

/// Native AVKit controller lifecycle for a local movie or audio artifact.
@MainActor
enum ChatArtifactMediaController {
    static func make(fileURL: URL) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = AVPlayer(url: fileURL)
        controller.videoGravity = .resizeAspect
        return controller
    }

    static func update(_ controller: AVPlayerViewController, fileURL: URL) {
        let currentURL = (controller.player?.currentItem?.asset as? AVURLAsset)?.url
        if currentURL != fileURL {
            controller.player?.pause()
            controller.player = AVPlayer(url: fileURL)
        }
    }

    static func dismantle(_ controller: AVPlayerViewController) {
        controller.player?.pause()
        controller.player = nil
    }
}
#endif
