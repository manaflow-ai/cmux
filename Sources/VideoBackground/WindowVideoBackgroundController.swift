import AppKit
import CmuxBrowser
import CmuxSettings
import ObjectiveC
import Observation

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
    private var isSystemSleeping = false
    private var hostView: VideoBackgroundHostView?
    private var playerView: (any VideoBackgroundPlayerView)?
    private var activeSource: VideoBackgroundSource?
    private var failedSourceText: String?
    private var observers: [any NSObjectProtocol] = []

    /// Installs (or refreshes) the controller for a main window.
    ///
    /// Idempotent; called from the window-chrome configuration pass so the
    /// layer's position below `contentView` is re-asserted after glass-root
    /// swaps and other content-view changes. Returns the window's controller
    /// so the caller can hand its ``presentation`` to the root backdrop.
    @discardableResult
    static func ensure(
        on window: NSWindow,
        defaults: UserDefaults = .standard,
        audioArbiter: VideoBackgroundAudioArbiter = .shared
    ) -> WindowVideoBackgroundController {
        let controller: WindowVideoBackgroundController
        if let existing = objc_getAssociatedObject(window, Self.associatedObjectKey)
            as? WindowVideoBackgroundController {
            controller = existing
        } else {
            controller = WindowVideoBackgroundController(window: window, defaults: defaults, audioArbiter: audioArbiter)
            objc_setAssociatedObject(window, Self.associatedObjectKey, controller, .OBJC_ASSOCIATION_RETAIN)
        }
        controller.refresh()
        return controller
    }

    private init(window: NSWindow, defaults: UserDefaults, audioArbiter: VideoBackgroundAudioArbiter) {
        self.window = window
        self.defaults = defaults
        self.audioArbiter = audioArbiter
        startObserving(window: window)
        audioArbiter.register(self, window: window)
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
        updatePlaybackState()
    }

    private func setSystemSleeping(_ sleeping: Bool) {
        isSystemSleeping = sleeping
        updatePlaybackState()
    }

    private var lastObservedEnabled: Bool?
    private var lastObservedSourceText: String?
    private var lastObservedMuted: Bool?

    private func refreshIfSettingsChanged() {
        let policy = VideoBackgroundSettings()
        let enabled = policy.isEnabled(defaults: defaults)
        let sourceText = policy.sourceText(defaults: defaults)
        let muted = policy.isMuted(defaults: defaults)
        guard enabled != lastObservedEnabled
            || sourceText != lastObservedSourceText
            || muted != lastObservedMuted else { return }
        refresh()
    }

    /// Reconciles the layer with the current settings and window state.
    func refresh() {
        guard let window else { return }

        let policy = VideoBackgroundSettings()
        let enabled = policy.isEnabled(defaults: defaults)
        let sourceText = policy.sourceText(defaults: defaults)
        lastObservedEnabled = enabled
        lastObservedSourceText = sourceText
        lastObservedMuted = policy.isMuted(defaults: defaults)

        if sourceText != failedSourceText {
            failedSourceText = nil
        }

        guard enabled,
              failedSourceText == nil,
              let source = VideoBackgroundSource.parse(sourceText) else {
            #if DEBUG
            cmuxDebugLog("videoBackground.refresh off enabled=\(enabled) latched=\(failedSourceText != nil) parsed=\(VideoBackgroundSource.parse(sourceText) != nil)")
            #endif
            removeLayer()
            return
        }

        installHostViewIfNeeded(in: window)
        if source != activeSource || playerView == nil {
            replacePlayerView(with: source)
        }
        updatePlaybackState()
        applyAudioState()
        presentation.isActive = playerView != nil
        #if DEBUG
        cmuxDebugLog("videoBackground.refresh on source=\(source) host=\(hostView != nil) player=\(playerView != nil) muted=\(effectiveMuted)")
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

    private func replacePlayerView(with source: VideoBackgroundSource) {
        playerView?.removeFromSuperview()
        playerView = nil
        activeSource = source
        guard let host = hostView else { return }

        let player: any VideoBackgroundPlayerView
        let muted = effectiveMuted
        switch source {
        case .youTubeVideo, .youTubePlaylist:
            player = VideoBackgroundWebPlayerView(source: source, muted: muted) { [weak self] reason in
                self?.handlePlayerFailure(reason: reason)
            }
        case let .localFile(url):
            player = VideoBackgroundLocalPlayerView(fileURL: url, muted: muted)
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
    func handlePlayerFailure(reason: String) {
        #if DEBUG
        cmuxDebugLog("videoBackground.playerFailure reason=\(reason)")
        #endif
        failedSourceText = lastObservedSourceText
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
        playerView.setPaused(!isVisible || isConservingPower)
    }

    private func removeLayer() {
        playerView?.setPaused(true)
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
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers.removeAll()
    }
}
