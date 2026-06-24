import AppKit
import AVKit
import CmuxPanes
import Foundation

@MainActor
final class FilePreviewMediaSession {
    private let viewSession = PanelOwnedNativeViewSession<AVPlayerView>(
        makeView: FilePreviewMediaSession.makeView,
        closeView: { view in
            view.player = nil
            view.removeFromSuperview()
        }
    )
    private var currentURL: URL?
    private var player: AVPlayer?

    deinit {
        // AppKit teardown is performed explicitly by close() on the main actor.
    }

    func view(
        panel: FilePreviewPanel,
        isVisibleInUI: Bool,
        backgroundColor: NSColor,
        drawsBackground: Bool
    ) -> AVPlayerView {
        viewSession.view {
            configure(
                $0,
                panel: panel,
                isVisibleInUI: isVisibleInUI,
                backgroundColor: backgroundColor,
                drawsBackground: drawsBackground
            )
        }
    }

    func update(
        _ view: AVPlayerView,
        panel: FilePreviewPanel,
        isVisibleInUI: Bool,
        backgroundColor: NSColor,
        drawsBackground: Bool
    ) {
        viewSession.update(view) {
            configure(
                $0,
                panel: panel,
                isVisibleInUI: isVisibleInUI,
                backgroundColor: backgroundColor,
                drawsBackground: drawsBackground
            )
        }
    }

    func close() {
        player?.pause()
        viewSession.close()
        player = nil
        currentURL = nil
    }

    private static func makeView() -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = true
        view.videoGravity = .resizeAspect
        return view
    }

    private func configure(
        _ view: AVPlayerView,
        panel: FilePreviewPanel,
        isVisibleInUI: Bool,
        backgroundColor: NSColor,
        drawsBackground: Bool
    ) {
        view.isHidden = !isVisibleInUI
        view.applyFilePreviewRootLayerBackground(
            backgroundColor: backgroundColor,
            drawsBackground: drawsBackground
        )
        panel.attachPreviewFocus(root: view, primaryResponder: view, intent: .mediaPlayer)
        updatePlayer(in: view, url: panel.fileURL)
    }

    private func updatePlayer(in playerView: AVPlayerView, url: URL) {
        guard currentURL != url else { return }
        player?.pause()
        currentURL = url
        let player = AVPlayer(url: url)
        self.player = player
        playerView.player = player
    }
}
