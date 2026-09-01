import AppKit

/// Decides which window is allowed to play the video background's audio.
///
/// Every main window runs its own player, but sound from several windows at
/// once is noise, so audio follows keyboard focus: the window that most
/// recently became key owns audio until another cmux window takes it, and it
/// keeps ownership while the user works in a different app. Windows that
/// don't own audio play silently. Ownership changes fan out to every
/// registered ``WindowVideoBackgroundController`` so their players re-apply
/// their effective mute state immediately.
@MainActor
final class VideoBackgroundAudioArbiter {
    private(set) weak var ownerWindow: NSWindow?
    private let controllers = NSHashTable<WindowVideoBackgroundController>.weakObjects()
    /// Windows admitted by ``register(_:window:)`` are the only valid audio
    /// handoff targets. A key auxiliary window must never become an audio
    /// owner merely because AppKit reports it as the fallback.
    private let registeredWindows = NSHashTable<NSWindow>.weakObjects()

    /// Creates an independent arbiter for one application composition root.
    init() {}

    deinit {}

    /// Registers a controller for ownership-change callbacks. The first window
    /// to register while no owner exists becomes the owner so a single window
    /// never waits for a key event before it may play audio.
    func register(_ controller: WindowVideoBackgroundController, window: NSWindow) {
        controllers.add(controller)
        registerWindow(window)
    }

    /// Admits a window to the audio ownership domain.
    ///
    /// This is separate from ``windowDidBecomeKey(_:)`` so an arbitrary
    /// auxiliary key window cannot self-register merely by sending a focus
    /// notification. The app controller uses ``register(_:window:)``; the
    /// narrow internal method keeps lifecycle tests on the same path.
    func registerWindow(_ window: NSWindow) {
        registeredWindows.add(window)
        if ownerWindow == nil || window.isKeyWindow {
            windowDidBecomeKey(window)
        }
    }

    /// Whether `window` currently owns audio.
    func mayPlayAudio(in window: NSWindow) -> Bool {
        ownerWindow === window
    }

    /// Transfers audio ownership to the window that just became key.
    func windowDidBecomeKey(_ window: NSWindow) {
        guard registeredWindows.contains(window) else { return }
        guard ownerWindow !== window else { return }
        ownerWindow = window
        notifyControllers()
    }

    /// Releases ownership held by a closing window, handing it to `fallback`
    /// (typically the app's current key window) when one exists.
    func windowWillClose(_ window: NSWindow, fallback: NSWindow?) {
        registeredWindows.remove(window)
        guard ownerWindow === window else { return }
        ownerWindow = fallback.flatMap { candidate in
            guard candidate !== window, registeredWindows.contains(candidate) else { return nil }
            return candidate
        }
        notifyControllers()
    }

    private func notifyControllers() {
        for controller in controllers.allObjects {
            controller.applyAudioState()
        }
    }
}
