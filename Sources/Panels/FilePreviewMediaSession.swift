import AppKit
import AVKit
import Foundation

@MainActor
final class FilePreviewMediaSession {
    private typealias PlaybackSnapshot = (
        position: CMTime,
        shouldResume: Bool,
        playbackRate: Float,
        selectionSourceItem: AVPlayerItem?
    )

    private let viewSession = PanelOwnedNativeViewSession<AVPlayerView>(
        makeView: FilePreviewMediaSession.makeView,
        closeView: { view in
            view.player = nil
            view.removeFromSuperview()
        }
    )
    private var currentURL: URL?
    private var currentRevision: Int?
    private var player: AVPlayer?
    var playbackRestoreTask: Task<Void, Never>?
    private var pendingPlaybackSnapshot: PlaybackSnapshot?

    deinit {
        // AppKit teardown is performed explicitly by close() on the main actor.
    }

    func view(
        panel: FilePreviewPanel,
        revision: Int,
        isVisibleInUI: Bool,
        backgroundColor: NSColor,
        drawsBackground: Bool
    ) -> AVPlayerView {
        viewSession.view {
            configure(
                $0,
                panel: panel,
                revision: revision,
                isVisibleInUI: isVisibleInUI,
                backgroundColor: backgroundColor,
                drawsBackground: drawsBackground
            )
        }
    }

    func update(
        _ view: AVPlayerView,
        panel: FilePreviewPanel,
        revision: Int,
        isVisibleInUI: Bool,
        backgroundColor: NSColor,
        drawsBackground: Bool
    ) {
        viewSession.update(view) {
            configure(
                $0,
                panel: panel,
                revision: revision,
                isVisibleInUI: isVisibleInUI,
                backgroundColor: backgroundColor,
                drawsBackground: drawsBackground
            )
        }
    }

    func close() {
        playbackRestoreTask?.cancel()
        playbackRestoreTask = nil
        pendingPlaybackSnapshot = nil
        player?.pause()
        viewSession.close()
        player = nil
        currentURL = nil
        currentRevision = nil
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
        revision: Int,
        isVisibleInUI: Bool,
        backgroundColor: NSColor,
        drawsBackground: Bool
    ) {
        view.isHidden = !isVisibleInUI
        FilePreviewNativeBackground.applyRootLayer(
            to: view,
            backgroundColor: backgroundColor,
            drawsBackground: drawsBackground
        )
        panel.attachPreviewFocus(root: view, primaryResponder: view, intent: .mediaPlayer)
        updatePlayer(in: view, url: panel.fileURL, revision: revision)
    }

    private func updatePlayer(in playerView: AVPlayerView, url: URL, revision: Int) {
        guard currentURL != url || currentRevision != revision else { return }
        if currentURL == url, let player {
            currentRevision = revision
            playerView.player = player
            replaceCurrentItem(in: player, url: url, revision: revision)
            return
        }

        playbackRestoreTask?.cancel()
        playbackRestoreTask = nil
        pendingPlaybackSnapshot = nil
        player?.pause()
        currentURL = url
        currentRevision = revision
        let player = AVPlayer(url: url)
        self.player = player
        playerView.player = player
    }

    private func replaceCurrentItem(in player: AVPlayer, url: URL, revision: Int) {
        playbackRestoreTask?.cancel()

        let snapshot: PlaybackSnapshot
        if let pendingPlaybackSnapshot {
            snapshot = pendingPlaybackSnapshot
        } else {
            let currentTime = player.currentTime()
            snapshot = (
                position: currentTime.isNumeric ? currentTime : .zero,
                shouldResume: player.timeControlStatus != .paused || player.rate != 0,
                playbackRate: player.rate == 0 ? player.defaultRate : player.rate,
                selectionSourceItem: player.currentItem
            )
            pendingPlaybackSnapshot = snapshot
        }
        let nextItem = AVPlayerItem(url: url)

        player.pause()
        player.replaceCurrentItem(with: nextItem)
        playbackRestoreTask = Task { [weak self, weak player] in
            guard let self, let player else { return }
            defer {
                finishPlaybackRestore(in: player, item: nextItem, revision: revision)
            }
            if let previousItem = snapshot.selectionSourceItem {
                await restoreMediaSelections(
                    from: previousItem,
                    to: nextItem,
                    in: player,
                    revision: revision
                )
            }
            guard canRestorePlayback(in: player, item: nextItem, revision: revision) else { return }

            let finished = await player.seek(
                to: snapshot.position,
                toleranceBefore: .zero,
                toleranceAfter: .zero
            )
            guard finished,
                  canRestorePlayback(in: player, item: nextItem, revision: revision) else { return }
            if snapshot.shouldResume {
                player.playImmediately(atRate: snapshot.playbackRate)
            }
        }
    }

    private func finishPlaybackRestore(
        in player: AVPlayer,
        item: AVPlayerItem,
        revision: Int
    ) {
        guard self.player === player,
              player.currentItem === item,
              currentRevision == revision else { return }
        playbackRestoreTask = nil
        pendingPlaybackSnapshot = nil
    }

    private func restoreMediaSelections(
        from previousItem: AVPlayerItem,
        to nextItem: AVPlayerItem,
        in player: AVPlayer,
        revision: Int
    ) async {
        let characteristics: [AVMediaCharacteristic]
        do {
            characteristics = try await previousItem.asset.load(
                .availableMediaCharacteristicsWithMediaSelectionOptions
            )
        } catch {
            return
        }
        guard canRestorePlayback(in: player, item: nextItem, revision: revision) else { return }

        for characteristic in characteristics {
            do {
                guard let previousGroup = try await previousItem.asset.loadMediaSelectionGroup(
                    for: characteristic
                ) else { continue }
                guard canRestorePlayback(in: player, item: nextItem, revision: revision) else { return }
                guard let selectedOption = previousItem.currentMediaSelection.selectedMediaOption(
                    in: previousGroup
                ) else { continue }

                guard let nextGroup = try await nextItem.asset.loadMediaSelectionGroup(
                    for: characteristic
                ) else { continue }
                guard canRestorePlayback(in: player, item: nextItem, revision: revision) else { return }
                guard let nextOption = nextGroup.mediaSelectionOption(
                    withPropertyList: selectedOption.propertyList()
                ) else { continue }
                nextItem.select(nextOption, in: nextGroup)
            } catch {
                continue
            }
        }
    }

    private func canRestorePlayback(
        in player: AVPlayer,
        item: AVPlayerItem,
        revision: Int
    ) -> Bool {
        !Task.isCancelled &&
            self.player === player &&
            player.currentItem === item &&
            currentRevision == revision
    }
}
