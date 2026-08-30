import AppKit
import CmuxBrowser
import CmuxSettings
import ObjectiveC
import Observation
import QuartzCore

/// Authoritative, observable playback state of one window's video background.
///
/// `isActive` is written only by ``WindowVideoBackgroundController`` and is
/// `true` exactly while a player view is installed below the window's content
/// view. The window-root backdrop dims against it — never against the raw
/// settings — so a failed embed (or a window without a usable theme frame)
/// restores the regular terminal background instead of leaving a dimmed fill
/// over nothing.
@MainActor
@Observable
final class VideoBackgroundPresentation {
    /// Whether a video player is currently installed in the window.
    fileprivate(set) var isActive = false
}

/// Coordinates the queue and monotonic playhead shared by every main window.
///
/// Each window still owns a lightweight player view (WebKit cannot be mounted
/// in two windows at once), but all controllers consume this one coordinator's
/// source index, generation, and elapsed playhead. A newly created terminal
/// therefore joins the currently playing item instead of restarting at zero;
/// an end event from any window advances every other window exactly once.
@MainActor
final class VideoBackgroundPlaybackCoordinator {
    /// Immutable state delivered to registered window controllers.
    struct Snapshot: Equatable {
        let sources: [VideoBackgroundSource]
        let index: Int
        let generation: UInt64
        let position: TimeInterval
        let quality: String

        /// The source currently playing, if the queue is non-empty.
        var currentSource: VideoBackgroundSource? {
            guard sources.indices.contains(index) else { return nil }
            return sources[index]
        }
    }

    private var sources: [VideoBackgroundSource] = []
    private var index = 0
    private var generation: UInt64 = 0
    private var quality = VideoBackgroundSettings.defaultQuality
    private var startedAt = CACurrentMediaTime()
    private var hasStarted = false
    private var observers: [UUID: @MainActor (Snapshot) -> Void] = [:]

    init() {}

    /// Replaces the shared queue when settings change and returns its current
    /// snapshot. Identical queues/quality leave the current item and playhead
    /// untouched so a settings notification cannot restart every window.
    func configure(sourceTexts: [String], quality: String) -> Snapshot {
        let normalizedQuality = VideoBackgroundSettings().normalizedQuality(quality)
        let parsedSources = sourceTexts.compactMap(VideoBackgroundSource.parse)
        guard parsedSources != sources || normalizedQuality != self.quality else {
            return snapshot()
        }

        sources = parsedSources
        self.quality = normalizedQuality
        index = 0
        generation &+= 1
        startedAt = CACurrentMediaTime()
        hasStarted = false
        let next = snapshot()
        notify(next)
        return next
    }

    /// Registers one controller callback and returns its token plus the latest
    /// shared state. The callback is main-actor isolated and never crosses a
    /// thread boundary.
    func register(_ observer: @escaping @MainActor (Snapshot) -> Void) -> (token: UUID, snapshot: Snapshot) {
        let token = UUID()
        observers[token] = observer
        return (token, snapshot())
    }

    /// Removes a controller callback after its window closes.
    func unregister(_ token: UUID?) {
        guard let token else { return }
        observers.removeValue(forKey: token)
    }

    /// Advances the queue exactly once for the generation that emitted an end
    /// event. Stale events from players being replaced are ignored.
    func advance(after generation: UInt64) {
        guard generation == self.generation, sources.count > 1 else { return }
        index = (index + 1) % sources.count
        self.generation &+= 1
        startedAt = CACurrentMediaTime()
        hasStarted = false
        notify(snapshot())
    }

    /// Anchors the monotonic clock to the first player that actually becomes
    /// ready for this generation. This avoids a late-created window joining a
    /// playhead that started counting while WebKit was still loading.
    func markStarted(for generation: UInt64) {
        guard generation == self.generation, !hasStarted else { return }
        startedAt = CACurrentMediaTime()
        hasStarted = true
    }

    /// Returns a fresh playhead snapshot without changing queue identity.
    func synchronizedSnapshot() -> Snapshot { snapshot() }

    private func snapshot(now: CFTimeInterval = CACurrentMediaTime()) -> Snapshot {
        Snapshot(
            sources: sources,
            index: index,
            generation: generation,
            position: hasStarted ? max(0, now - startedAt) : 0,
            quality: quality
        )
    }

    private func notify(_ value: Snapshot) {
        for observer in Array(observers.values) {
            observer(value)
        }
    }
}

/// Owns one main window's dynamic video background layer.
///
/// The layer is a non-interactive host view installed in the window's theme
/// frame *below* `contentView`, so the SwiftUI window-root backdrop (drawn at
/// the configured dim opacity) and every terminal surface composite on top of
/// it. The controller reacts to the `terminal.videoBackground.*` settings
/// live, and pauses playback whenever it could not be seen anyway — the
/// window is occluded or minimized, the system is asleep, or Low Power Mode
/// is on — driven by real notifications, never by polling. Audio is an
/// opt-in and, even then, only the window that owns it per
/// ``VideoBackgroundAudioArbiter`` plays sound.
@MainActor
final class WindowVideoBackgroundController {
    private static let associatedObjectKey = UnsafeRawPointer(
        UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)
    )

    /// Playback state the window-root backdrop observes.
    let presentation = VideoBackgroundPresentation()

    private weak var window: NSWindow?
    private let defaults: UserDefaults
    private let audioArbiter: VideoBackgroundAudioArbiter
    private let playbackCoordinator: VideoBackgroundPlaybackCoordinator
    private var playbackObserverToken: UUID?
    private var isSystemSleeping = false
    private var hostView: VideoBackgroundHostView?
    private var playerView: (any VideoBackgroundPlayerView)?
    private var activeSource: VideoBackgroundSource?
    private var failedSourceText: String?
    private var observers: [any NSObjectProtocol] = []
    private var playerGeneration: UInt64 = 0
    private var playerQuality = VideoBackgroundSettings.defaultQuality
    private var playerVolume = VideoBackgroundSettings.defaultVolume
    private var lastPlayerPaused: Bool?

    /// Installs (or refreshes) the controller for a main window.
    ///
    /// Idempotent; called from the window-chrome configuration pass so the
    /// layer's position below `contentView` is re-asserted after glass-root
    /// swaps and other content-view changes. Returns the window's controller
    /// so the caller can hand its ``presentation`` to the root backdrop.
    @discardableResult
    static func ensure(
        on window: NSWindow,
        audioArbiter: VideoBackgroundAudioArbiter,
        playbackCoordinator: VideoBackgroundPlaybackCoordinator,
        defaults: UserDefaults = .standard
    ) -> WindowVideoBackgroundController {
        let controller: WindowVideoBackgroundController
        if let existing = objc_getAssociatedObject(window, Self.associatedObjectKey)
            as? WindowVideoBackgroundController {
            controller = existing
        } else {
            controller = WindowVideoBackgroundController(
                window: window,
                defaults: defaults,
                audioArbiter: audioArbiter,
                playbackCoordinator: playbackCoordinator
            )
            objc_setAssociatedObject(window, Self.associatedObjectKey, controller, .OBJC_ASSOCIATION_RETAIN)
        }
        controller.refresh()
        return controller
    }

    private init(
        window: NSWindow,
        defaults: UserDefaults,
        audioArbiter: VideoBackgroundAudioArbiter,
        playbackCoordinator: VideoBackgroundPlaybackCoordinator
    ) {
        self.window = window
        self.defaults = defaults
        self.audioArbiter = audioArbiter
        self.playbackCoordinator = playbackCoordinator
        startObserving(window: window)
        audioArbiter.register(self, window: window)
        playbackObserverToken = playbackCoordinator.register { [weak self] snapshot in
            self?.applyPlaybackSnapshot(snapshot)
        }.token
    }

    /// Registers synchronously so no transition can slip through between
    /// install and the window's first paint: an `AsyncSequence`-based
    /// observer inside a `Task` only starts listening once that task runs,
    /// which is after the window has typically already become visible.
    private func startObserving(window: NSWindow) {
        let center = NotificationCenter.default
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        func observe(
            _ name: Notification.Name,
            object: Any?,
            in notificationCenter: NotificationCenter = center,
            _ action: @escaping @Sendable @MainActor (WindowVideoBackgroundController) -> Void
        ) {
            observers.append(notificationCenter.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    action(self)
                }
            })
        }
        observe(UserDefaults.didChangeNotification, object: nil) { $0.refreshIfSettingsChanged() }
        observe(NSWindow.didChangeOcclusionStateNotification, object: window) { $0.updatePlaybackState() }
        observe(NSWindow.didBecomeKeyNotification, object: window) { $0.windowDidBecomeKey() }
        observe(NSWindow.didResignKeyNotification, object: window) { $0.updatePlaybackState() }
        observe(NSWindow.didMiniaturizeNotification, object: window) { $0.updatePlaybackState() }
        observe(NSWindow.didDeminiaturizeNotification, object: window) { $0.updatePlaybackState() }
        observe(NSWindow.willCloseNotification, object: window) { $0.tearDownForWindowClose() }
        // Performance guardrails: no point decoding video nobody can see.
        observe(NSWorkspace.willSleepNotification, object: nil, in: workspaceCenter) { $0.setSystemSleeping(true) }
        observe(NSWorkspace.didWakeNotification, object: nil, in: workspaceCenter) { $0.setSystemSleeping(false) }
        observe(.NSProcessInfoPowerStateDidChange, object: nil) { $0.updatePlaybackState() }
    }

    private func windowDidBecomeKey() {
        guard let window else { return }
        audioArbiter.windowDidBecomeKey(window)
        let snapshot = playbackCoordinator.synchronizedSnapshot()
        if snapshot.position > 0 {
            playerView?.setPlaybackPosition(snapshot.position)
        }
        updatePlaybackState()
    }

    private func setSystemSleeping(_ sleeping: Bool) {
        isSystemSleeping = sleeping
        updatePlaybackState()
    }

    private var lastObservedEnabled: Bool?
    private var lastObservedSourceText: String?
    private var lastObservedMuted: Bool?
    private var lastObservedQueue: [String]?
    private var lastObservedQuality: String?
    private var lastObservedVolume: Double?

    private func refreshIfSettingsChanged() {
        let policy = VideoBackgroundSettings()
        let enabled = policy.isEnabled(defaults: defaults)
        let sourceText = policy.sourceText(defaults: defaults)
        let muted = policy.isMuted(defaults: defaults)
        let queue = policy.queue(defaults: defaults)
        let quality = policy.quality(defaults: defaults)
        let volume = policy.volume(defaults: defaults)
        guard enabled != lastObservedEnabled
            || sourceText != lastObservedSourceText
            || muted != lastObservedMuted
            || queue != lastObservedQueue
            || quality != lastObservedQuality
            || volume != lastObservedVolume else { return }
        refresh()
    }

    /// Reconciles the layer with the current settings and window state.
    func refresh() {
        guard let window else { return }

        let policy = VideoBackgroundSettings()
        let enabled = policy.isEnabled(defaults: defaults)
        let sourceText = policy.sourceText(defaults: defaults)
        let queue = policy.queue(defaults: defaults)
        lastObservedEnabled = enabled
        lastObservedSourceText = sourceText
        lastObservedMuted = policy.isMuted(defaults: defaults)
        lastObservedQueue = queue
        lastObservedQuality = policy.quality(defaults: defaults)
        lastObservedVolume = policy.volume(defaults: defaults)

        let sourceTexts = policy.effectiveSourceTexts(defaults: defaults)
        let sharedSnapshot = playbackCoordinator.configure(
            sourceTexts: sourceTexts,
            quality: lastObservedQuality ?? VideoBackgroundSettings.defaultQuality
        )

        let sourceSignature = sourceTexts.joined(separator: "\u{1F}" )
        if sourceSignature != failedSourceText {
            failedSourceText = nil
        }

        guard enabled,
              failedSourceText == nil,
              sharedSnapshot.currentSource != nil else {
            #if DEBUG
            cmuxDebugLog("videoBackground.refresh off enabled=\(enabled) latched=\(failedSourceText != nil) parsed=\(sharedSnapshot.currentSource != nil)")
            #endif
            removeLayer()
            return
        }

        installHostViewIfNeeded(in: window)
        applyPlaybackSnapshot(sharedSnapshot)
        applyAudioState()
        #if DEBUG
        cmuxDebugLog("videoBackground.refresh on source=\(String(describing: sharedSnapshot.currentSource)) host=\(hostView != nil) player=\(playerView != nil) muted=\(effectiveMuted) queue=\(sharedSnapshot.sources.count) quality=\(sharedSnapshot.quality)")
        #endif
    }

    /// Whether this window's player must be silent right now: the setting
    /// wins, and otherwise only the arbiter's audio owner may play sound.
    var effectiveMuted: Bool {
        guard lastObservedMuted == false, let window else { return true }
        return !audioArbiter.mayPlayAudio(in: window)
    }

    /// Re-applies ``effectiveMuted`` to the installed player. Called by the
    /// arbiter whenever audio ownership moves between windows.
    func applyAudioState() {
        playerView?.setMuted(effectiveMuted)
        playerView?.setVolume(playerVolume)
    }

    /// Applies the coordinator's authoritative source/playhead to this window.
    /// A callback may arrive while `refresh()` is still installing the host, so
    /// the host is asserted here as well as in the caller.
    private func applyPlaybackSnapshot(
        _ snapshot: VideoBackgroundPlaybackCoordinator.Snapshot
    ) {
        guard let window,
              lastObservedEnabled != false,
              let source = snapshot.currentSource else {
            return
        }
        installHostViewIfNeeded(in: window)
        let needsReplacement = playerView == nil
            || activeSource != source
            || playerGeneration != snapshot.generation
            || playerQuality != snapshot.quality
        if needsReplacement {
            replacePlayerView(
                with: source,
                position: snapshot.position,
                loops: snapshot.sources.count <= 1,
                generation: snapshot.generation,
                quality: snapshot.quality,
                volume: lastObservedVolume ?? VideoBackgroundSettings.defaultVolume
            )
        } else if snapshot.position > 0 {
            // Re-assert the shared playhead when a window becomes visible or a
            // peer advances. The player implementations deduplicate tiny moves.
            playerView?.setPlaybackPosition(snapshot.position)
        }
        playerView?.setVolume(lastObservedVolume ?? VideoBackgroundSettings.defaultVolume)
        updatePlaybackState()
        applyAudioState()
        presentation.isActive = playerView != nil
    }

    private func installHostViewIfNeeded(in window: NSWindow) {
        guard let contentView = window.contentView,
              let themeFrame = contentView.superview else { return }

        let host: VideoBackgroundHostView
        if let existing = hostView {
            host = existing
        } else {
            host = VideoBackgroundHostView(frame: themeFrame.bounds)
            host.translatesAutoresizingMaskIntoConstraints = false
            hostView = host
        }

        // Re-adding on the same parent re-asserts the below-content ordering
        // after a glass-root swap replaces `contentView`.
        if host.superview !== themeFrame {
            host.removeFromSuperview()
            themeFrame.addSubview(host, positioned: .below, relativeTo: contentView)
            NSLayoutConstraint.activate([
                host.topAnchor.constraint(equalTo: themeFrame.topAnchor),
                host.bottomAnchor.constraint(equalTo: themeFrame.bottomAnchor),
                host.leadingAnchor.constraint(equalTo: themeFrame.leadingAnchor),
                host.trailingAnchor.constraint(equalTo: themeFrame.trailingAnchor),
            ])
        } else {
            themeFrame.addSubview(host, positioned: .below, relativeTo: contentView)
        }
    }

    private func replacePlayerView(
        with source: VideoBackgroundSource,
        position: TimeInterval,
        loops: Bool,
        generation: UInt64,
        quality: String,
        volume: Double
    ) {
        playerView?.removeFromSuperview()
        playerView = nil
        activeSource = source
        playerGeneration = generation
        playerQuality = quality
        playerVolume = volume
        guard let host = hostView else { return }

        let player: any VideoBackgroundPlayerView
        let muted = effectiveMuted
        switch source {
        case .youTubeVideo, .youTubePlaylist:
            player = VideoBackgroundWebPlayerView(
                source: source,
                muted: muted,
                queueManaged: !loops,
                quality: quality,
                volume: volume,
                initialPosition: position,
                onFailure: { [weak self] reason in
                    self?.handlePlayerFailure(reason: reason, generation: generation)
                },
                onEnded: { [weak self] in
                    guard let self else { return }
                    self.playbackCoordinator.advance(after: generation)
                },
                onReady: { [weak self] in
                    self?.playbackCoordinator.markStarted(for: generation)
                }
            )
        case let .localFile(url):
            player = VideoBackgroundLocalPlayerView(
                fileURL: url,
                muted: muted,
                volume: volume,
                loops: loops,
                initialPosition: position,
                onEnded: { [weak self] in
                    guard let self else { return }
                    self.playbackCoordinator.advance(after: generation)
                },
                onStarted: { [weak self] in
                    self?.playbackCoordinator.markStarted(for: generation)
                }
            )
        }

        player.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(player)
        NSLayoutConstraint.activate([
            player.topAnchor.constraint(equalTo: host.topAnchor),
            player.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            player.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            player.trailingAnchor.constraint(equalTo: host.trailingAnchor),
        ])
        playerView = player
    }

    /// Fails gracefully: the layer disappears, ``presentation`` reports
    /// inactive so the backdrop stops dimming, and the terminal is untouched.
    /// The failed source is remembered so a broken embed doesn't reload in a
    /// loop; editing the source setting clears the latch and retries.
    func handlePlayerFailure(reason: String, generation: UInt64? = nil) {
        #if DEBUG
        cmuxDebugLog("videoBackground.playerFailure reason=\(reason)")
        #endif
        if let generation,
           playbackCoordinator.synchronizedSnapshot().sources.count > 1 {
            // A broken entry should not silence an otherwise valid queue. The
            // coordinator advances every window and generation-gates duplicate
            // WebKit/AVFoundation failures from the same item.
            playbackCoordinator.advance(after: generation)
            return
        }
        let failedSources: [String]
        if let queue = lastObservedQueue, !queue.isEmpty {
            failedSources = queue
        } else {
            failedSources = [lastObservedSourceText ?? ""]
        }
        failedSourceText = failedSources.joined(separator: "\u{1F}")
        removeLayer()
    }

    /// Plays only while the window is actually visible and the machine isn't
    /// asleep or conserving power; every input is a real system signal.
    private func updatePlaybackState() {
        guard let window, let playerView else { return }
        // AppKit reports cmux's transparent main window as fully occluded even
        // while it is frontmost and uncovered (observed on macOS 26; the debug
        // render stats in `GhosttyTerminalView` apply the same key-window
        // fallback), so the key window always counts as visible.
        let occlusionVisible = window.occlusionState.contains(.visible) || window.isKeyWindow
        let isVisible = occlusionVisible && !window.isMiniaturized && window.isVisible
        let isConservingPower = isSystemSleeping || ProcessInfo.processInfo.isLowPowerModeEnabled
        #if DEBUG
        cmuxDebugLog("videoBackground.playback paused=\(!isVisible || isConservingPower) visible=\(isVisible) occluded=\(!window.occlusionState.contains(.visible)) key=\(window.isKeyWindow) mini=\(window.isMiniaturized) sleeping=\(isSystemSleeping) lowPower=\(ProcessInfo.processInfo.isLowPowerModeEnabled)")
        #endif
        let shouldPause = !isVisible || isConservingPower
        if lastPlayerPaused != shouldPause, !shouldPause {
            let snapshot = playbackCoordinator.synchronizedSnapshot()
            if snapshot.position > 0 {
                playerView.setPlaybackPosition(snapshot.position)
            }
        }
        lastPlayerPaused = shouldPause
        playerView.setPaused(shouldPause)
    }

    private func removeLayer() {
        playerView?.setPaused(true)
        lastPlayerPaused = true
        playerView?.removeFromSuperview()
        playerView = nil
        activeSource = nil
        hostView?.removeFromSuperview()
        hostView = nil
        presentation.isActive = false
    }

    private func tearDownForWindowClose() {
        if let window {
            audioArbiter.windowWillClose(window, fallback: NSApp.keyWindow)
        }
        removeLayer()
        playbackCoordinator.unregister(playbackObserverToken)
        playbackObserverToken = nil
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers.removeAll()
    }
}
