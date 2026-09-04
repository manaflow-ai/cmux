import AppKit
import CmuxBrowser
import CmuxSettings
import ObjectiveC
import Observation
import QuartzCore

/// Authoritative, observable playback state of one window's video background.
///
/// `isActive` is written only by ``WindowVideoBackgroundController`` and is
/// `true` only after the installed player confirms that it can render. The
/// window-root backdrop dims against it — never against the raw settings — so
/// a loading or failed player (or a window without a usable theme frame)
/// restores the regular terminal background instead of leaving a dimmed fill
/// over nothing.
@MainActor
@Observable
final class VideoBackgroundPresentation {
    /// Whether the installed video player has confirmed render readiness.
    fileprivate(set) var isActive = false
}

/// Coordinates the queue and monotonic playhead shared by every main window.
///
/// Each window still owns a lightweight player view (WebKit cannot be mounted
/// in two windows at once), but all controllers consume this one coordinator's
/// source index, generation, and elapsed playhead. A newly created terminal
/// therefore joins the currently playing item instead of restarting at zero;
/// an end event from any window advances every other window exactly once. The
/// clock advances only while at least one registered player is running, and a
/// failed queue entry is skipped at most once so an all-failing queue settles.
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

    private let now: () -> CFTimeInterval
    private var sources: [VideoBackgroundSource] = []
    private var index = 0
    private var generation: UInt64 = 0
    private var quality = VideoBackgroundSettings.defaultQuality
    private var failedIndices: Set<Int> = []
    private var isExhausted = false
    private var accumulatedPosition: TimeInterval = 0
    private var runningSince: CFTimeInterval?
    private var runningTokens: Set<UUID> = []
    private var observers: [UUID: @MainActor (Snapshot) -> Void] = [:]

    /// Creates a coordinator using a monotonic clock; tests can inject a
    /// deterministic clock without waiting on wall time.
    init(now: @escaping () -> CFTimeInterval = { CACurrentMediaTime() }) {
        self.now = now
    }

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
        failedIndices.removeAll()
        isExhausted = false
        index = 0
        generation &+= 1
        resetClock()
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
        if runningTokens.remove(token) != nil, runningTokens.isEmpty {
            freezeClock()
        }
        observers.removeValue(forKey: token)
    }

    /// Records whether one registered player is currently able to advance the
    /// shared playhead. The clock runs while at least one player is running and
    /// is frozen as soon as the last player pauses or is removed.
    func setPlayerRunning(_ running: Bool, for token: UUID?) {
        guard let token, observers[token] != nil else { return }
        if running {
            guard runningTokens.insert(token).inserted else { return }
            if runningTokens.count == 1 {
                runningSince = now()
            }
        } else if runningTokens.remove(token) != nil, runningTokens.isEmpty {
            freezeClock()
        }
    }

    /// Advances the queue exactly once for the generation that emitted an end
    /// event. Stale events from players being replaced are ignored.
    func advance(after generation: UInt64) {
        guard generation == self.generation, sources.count > 1, !isExhausted else { return }
        advanceToNextPlayableSource()
    }

    /// Marks the current source as failed and advances at most once for this
    /// generation. Once every queued source has failed, the snapshot becomes
    /// empty so controllers tear down instead of retrying forever.
    func recordFailure(after generation: UInt64) {
        guard generation == self.generation,
              !isExhausted,
              sources.indices.contains(index) else { return }
        failedIndices.insert(index)
        advanceToNextPlayableSource()
    }

    /// Returns a fresh playhead snapshot without changing queue identity.
    func synchronizedSnapshot() -> Snapshot { snapshot() }

    private func snapshot() -> Snapshot {
        Snapshot(
            sources: sources,
            index: index,
            generation: generation,
            position: currentPosition(),
            quality: quality
        )
    }

    private func currentPosition() -> TimeInterval {
        guard let runningSince else { return accumulatedPosition }
        return accumulatedPosition + max(0, now() - runningSince)
    }

    private func freezeClock() {
        guard runningSince != nil else { return }
        accumulatedPosition = currentPosition()
        self.runningSince = nil
    }

    private func resetClock() {
        accumulatedPosition = 0
        runningSince = nil
        runningTokens.removeAll()
    }

    private func advanceToNextPlayableSource() {
        resetClock()
        guard let nextIndex = nextPlayableIndex() else {
            isExhausted = true
            index = sources.count
            generation &+= 1
            notify(snapshot())
            return
        }
        index = nextIndex
        self.generation &+= 1
        notify(snapshot())
    }

    private func nextPlayableIndex() -> Int? {
        guard !sources.isEmpty else { return nil }
        for offset in 1...sources.count {
            let candidate = (index + offset) % sources.count
            if !failedIndices.contains(candidate) {
                return candidate
            }
        }
        return nil
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
    private var lastPlayerPaused: Bool?
    private var playerIsReady = false

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
        cmuxDebugLog("videoBackground.refresh on sourceKind=\(sourceKind(sharedSnapshot.currentSource)) host=\(hostView != nil) player=\(playerView != nil) muted=\(effectiveMuted) queue=\(sharedSnapshot.sources.count) quality=\(sharedSnapshot.quality)")
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
        // Volume is a live setting; the replacement-time value can be stale
        // when the player remains installed while the slider changes.
        playerView?.setVolume(lastObservedVolume ?? VideoBackgroundSettings.defaultVolume)
    }

    /// Applies the coordinator's authoritative source/playhead to this window.
    /// A callback may arrive while `refresh()` is still installing the host, so
    /// the host is asserted here as well as in the caller.
    private func applyPlaybackSnapshot(
        _ snapshot: VideoBackgroundPlaybackCoordinator.Snapshot
    ) {
        guard let window, lastObservedEnabled != false else {
            playbackCoordinator.setPlayerRunning(false, for: playbackObserverToken)
            return
        }
        guard let source = snapshot.currentSource else {
            removeLayer()
            return
        }
        installHostViewIfNeeded(in: window)
        let needsReplacement = playerView == nil
            || activeSource != source
            || playerGeneration != snapshot.generation
            || playerQuality != snapshot.quality
        if needsReplacement {
            playerIsReady = false
            presentation.isActive = false
            playbackCoordinator.setPlayerRunning(false, for: playbackObserverToken)
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
        presentation.isActive = playerIsReady
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

    private func sourceKind(_ source: VideoBackgroundSource?) -> String {
        switch source {
        case .youTubeVideo: return "youtube-video"
        case .youTubePlaylist: return "youtube-playlist"
        case .localFile: return "local-file"
        case nil: return "none"
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
        playbackCoordinator.setPlayerRunning(false, for: playbackObserverToken)
        playerView?.removeFromSuperview()
        playerView = nil
        playerIsReady = false
        activeSource = source
        playerGeneration = generation
        playerQuality = quality
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
                    self?.playerDidBecomeReady(for: generation)
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
                onReady: { [weak self] in
                    self?.playerDidBecomeReady(for: generation)
                },
                onFailure: { [weak self] reason in
                    self?.handlePlayerFailure(reason: reason, generation: generation)
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

    /// Publishes active playback only after the underlying player confirms it
    /// can render. This keeps the window backdrop normal while WebKit or
    /// AVFoundation is still loading (or has failed).
    private func playerDidBecomeReady(for generation: UInt64) {
        guard generation == playerGeneration, playerView != nil else { return }
        playerIsReady = true
        presentation.isActive = true
        updatePlaybackState()
    }

    /// Fails gracefully: the layer disappears, ``presentation`` reports
    /// inactive so the backdrop stops dimming, and the terminal is untouched.
    /// The failed source is remembered so a broken embed doesn't reload in a
    /// loop; editing the source setting clears the latch and retries.
    func handlePlayerFailure(reason: String, generation: UInt64? = nil) {
        let currentSnapshot = playbackCoordinator.synchronizedSnapshot()
        if let generation {
            // A player can report an asynchronous failure after its source has
            // already been replaced. Never let that stale callback tear down
            // the newer player or latch the current source as failed.
            guard generation == currentSnapshot.generation,
                  generation == playerGeneration,
                  playerView != nil,
                  lastObservedEnabled != false else { return }
        }
        #if DEBUG
        cmuxDebugLog("videoBackground.playerFailure reason=\(reason)")
        #endif
        playbackCoordinator.setPlayerRunning(false, for: playbackObserverToken)
        playbackCoordinator.recordFailure(after: generation ?? currentSnapshot.generation)
        if playbackCoordinator.synchronizedSnapshot().currentSource == nil {
            let failedSources: [String]
            if let queue = lastObservedQueue, !queue.isEmpty {
                failedSources = queue
            } else {
                failedSources = [lastObservedSourceText ?? ""]
            }
            failedSourceText = failedSources.joined(separator: "\u{1F}")
            removeLayer()
        }
    }

    /// Plays only while the window is actually visible and the machine isn't
    /// asleep or conserving power; every input is a real system signal.
    private func updatePlaybackState() {
        guard let window, let playerView else {
            playbackCoordinator.setPlayerRunning(false, for: playbackObserverToken)
            return
        }
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
        playbackCoordinator.setPlayerRunning(
            playerIsReady && !shouldPause,
            for: playbackObserverToken
        )
    }

    private func removeLayer() {
        playbackCoordinator.setPlayerRunning(false, for: playbackObserverToken)
        playerView?.setPaused(true)
        lastPlayerPaused = true
        playerView?.removeFromSuperview()
        playerView = nil
        playerIsReady = false
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
