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
    private var registeredWindows: [WindowReference] = []

    private final class WindowReference {
        weak var window: NSWindow?

        init(_ window: NSWindow) {
            self.window = window
        }
    }

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
        if !registeredWindows.contains(where: { $0.window === window }) {
            registeredWindows.append(WindowReference(window))
        }
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
        guard registeredWindows.contains(where: { $0.window === window }) else { return }
        registeredWindows.removeAll { $0.window == nil || $0.window === window }
        registeredWindows.insert(WindowReference(window), at: 0)
        guard ownerWindow !== window else { return }
        ownerWindow = window
        notifyControllers()
    }

    /// Releases a closing owner to a registered fallback or the most recently
    /// focused surviving window, even before AppKit chooses a new key window.
    func windowWillClose(_ window: NSWindow, fallback: NSWindow?) {
        registeredWindows.removeAll { $0.window == nil || $0.window === window }
        guard ownerWindow === window else { return }
        ownerWindow = fallback.flatMap { candidate in
            guard registeredWindows.contains(where: { $0.window === candidate }) else { return nil }
            return candidate
        } ?? registeredWindows.first?.window
        notifyControllers()
    }

    private func notifyControllers() {
        for controller in controllers.allObjects {
            controller.applyAudioState()
        }
    }
}
