/// Sleepy Mode (`palette.sleepyMode`, classic #6740): a full-screen keep-awake screensaver.
/// On, it keeps the Mac and its display awake (``SleepyKeepAwakeHolding``) and covers every
/// screen with the sleepy scene (``SleepyOverlayPresenting``); any key or click on the scene, or
/// a second run of the action, wakes it. It is not a lock: the scene's Lock Mac button runs the
/// real macOS lock (`SleepyMacLock`). One per app (`AppServices.sleepyMode`); every entrypoint runs ``toggle()``.
@MainActor
public final class SleepyModeController {
    private let keepAwake: any SleepyKeepAwakeHolding
    private let overlay: any SleepyOverlayPresenting

    public private(set) var isActive = false

    public init(keepAwake: any SleepyKeepAwakeHolding, overlay: any SleepyOverlayPresenting) {
        self.keepAwake = keepAwake
        self.overlay = overlay
    }

    public func toggle() {
        if isActive { deactivate() } else { activate() }
    }

    public func activate() {
        guard !isActive else { return }
        isActive = true
        keepAwake.begin()
        overlay.show { [weak self] in self?.deactivate() }
    }

    public func deactivate() {
        guard isActive else { return }
        isActive = false
        overlay.hide()
        keepAwake.end()
    }

    /// The app's key-down gate: while the scene shows, a key wakes it and
    /// goes nowhere else (no shortcut runs behind the cover).
    public func consumesKeyDown() -> Bool {
        guard isActive else { return false }
        deactivate()
        return true
    }
}
