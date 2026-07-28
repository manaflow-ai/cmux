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

    private struct PlaybackTransportState {
        let position: CMTime
        let rate: Float
        let defaultRate: Float
        let timeControlStatus: AVPlayer.TimeControlStatus

        init(player: AVPlayer) {
            position = player.currentTime()
            rate = player.rate
            defaultRate = player.defaultRate
            timeControlStatus = player.timeControlStatus
        }

        func matches(_ player: AVPlayer, includingPosition: Bool) -> Bool {
            if includingPosition,
               CMTimeCompare(position, player.currentTime()) != 0 {
                return false
            }
            return rate == player.rate &&
                defaultRate == player.defaultRate &&
                timeControlStatus == player.timeControlStatus
        }
    }

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
    private var playbackRateObserver: NSObjectProtocol?
    private var playbackTransportCommandGeneration = 0

    deinit {
        playbackRestoreTask?.cancel()
        player?.currentItem?.cancelPendingSeeks()
        if let playbackRateObserver {
            NotificationCenter.default.removeObserver(playbackRateObserver)
        }
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
        cancelPlaybackRestore(in: player?.currentItem)
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

        cancelPlaybackRestore(in: player?.currentItem)
        pendingPlaybackSnapshot = nil
        player?.pause()
        currentURL = url
        currentRevision = revision
        let player = AVPlayer(url: url)
        self.player = player
        playerView.player = player
    }

    private func replaceCurrentItem(in player: AVPlayer, url: URL, revision: Int) {
        cancelPlaybackRestore(in: player.currentItem)

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
        let transportCommandGeneration = beginPlaybackTransportObservation(for: player)
        let transportState = PlaybackTransportState(player: player)
        let canContinue: @MainActor () -> Bool = { [weak self, weak player, weak nextItem] in
            guard let self, let player, let nextItem else { return false }
            return self.playbackTransportCommandGeneration == transportCommandGeneration &&
                self.canRestorePlayback(
                    in: player,
                    item: nextItem,
                    revision: revision
                )
        }
        playbackRestoreTask = Task { [weak self, weak player, weak nextItem] in
            defer {
                if let player, let nextItem {
                    self?.finishPlaybackRestore(
                        in: player,
                        item: nextItem,
                        revision: revision
                    )
                }
            }
            if let previousItem = snapshot.selectionSourceItem,
               let nextItem {
                await Self.restoreMediaSelections(
                    from: previousItem,
                    to: nextItem,
                    canContinue: canContinue
                )
            }
            guard canContinue(),
                  let player,
                  transportState.matches(player, includingPosition: true) else { return }

            let finished = await player.seek(
                to: snapshot.position,
                toleranceBefore: .zero,
                toleranceAfter: .zero
            )
            guard finished,
                  canContinue(),
                  transportState.matches(player, includingPosition: false) else { return }
            if snapshot.shouldResume {
                player.playImmediately(atRate: snapshot.playbackRate)
            }
        }
    }

    private func cancelPlaybackRestore(in item: AVPlayerItem?) {
        endPlaybackTransportObservation()
        playbackRestoreTask?.cancel()
        playbackRestoreTask = nil
        item?.cancelPendingSeeks()
    }

    private func beginPlaybackTransportObservation(for player: AVPlayer) -> Int {
        endPlaybackTransportObservation()
        playbackTransportCommandGeneration &+= 1
        let generation = playbackTransportCommandGeneration
        playbackRateObserver = NotificationCenter.default.addObserver(
            forName: AVPlayer.rateDidChangeNotification,
            object: player,
            queue: .main
        ) { [weak self] _ in
            // OperationQueue.main delivery keeps the callback on this session's actor.
            MainActor.assumeIsolated {
                self?.playbackTransportCommandGeneration &+= 1
            }
        }
        return generation
    }

    private func endPlaybackTransportObservation() {
        if let playbackRateObserver {
            NotificationCenter.default.removeObserver(playbackRateObserver)
            self.playbackRateObserver = nil
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
        endPlaybackTransportObservation()
        playbackRestoreTask = nil
        pendingPlaybackSnapshot = nil
    }

    private static func restoreMediaSelections(
        from previousItem: AVPlayerItem,
        to nextItem: AVPlayerItem,
        canContinue: @MainActor () -> Bool
    ) async {
        let characteristics: [AVMediaCharacteristic]
        do {
            characteristics = try await previousItem.asset.load(
                .availableMediaCharacteristicsWithMediaSelectionOptions
            )
        } catch {
            return
        }
        guard canContinue() else { return }

        for characteristic in characteristics {
            do {
                guard let previousGroup = try await previousItem.asset.loadMediaSelectionGroup(
                    for: characteristic
                ) else { continue }
                guard canContinue() else { return }
                guard let selectedOption = previousItem.currentMediaSelection.selectedMediaOption(
                    in: previousGroup
                ) else { continue }

                guard let nextGroup = try await nextItem.asset.loadMediaSelectionGroup(
                    for: characteristic
                ) else { continue }
                guard canContinue() else { return }
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
