import AppKit
import CmuxNextInput

/// Watches only the host window's intentional Command/Control/Option holds; a key or a click (Option-click) hides and suppresses. It never consumes input.
///
/// While hints are enabled, one window-scoped observe subscription to the app's input tap
/// (p04-input.md 3 (A)) hears this window's modifier changes, key-downs and mouse-downs. Observers run
/// before the key router, so a key the router consumes still hides the hints. While hints show, the
/// tap's `hintsShowing` flag is set, so per-key work elsewhere checks it in O(1).
@MainActor
final class WindowScopedShortcutHintModifierMonitor {
    private weak var window: NSWindow?
    private let tap: InputEventTap
    private let clock: any Clock<Duration>
    private let changed: (NSEvent.ModifierFlags?) -> Void
    private let keepsHints: (NSEvent) -> Bool
    private let isFront: @MainActor (NSWindow) -> Bool
    private var policy = ShortcutHintModifierPolicy()
    private var subscription: InputSubscription?
    private var observers: [NSObjectProtocol] = []
    private var pending: Task<Void, Never>?
    private var enabled = false
    /// Hints show in this window now; the tap's `hintsShowing` flag is set while it is true.
    private(set) var showing = false
    private var currentFlags: NSEvent.ModifierFlags = []
    #if DEBUG || CMUX_BENCH_HOOKS
    private let capture = ShortcutHintCaptureWaiter()
    #endif

    /// - Parameters:
    ///   - tap: The app's input tap.
    ///   - isFront: Whether the window is the one a hold shows hints in (the active app's key window).
    ///   - keepsHints: Whether a key-down leaves the hints up (a pane-navigation key); others hide them until release.
    ///   - changed: The held set to show hints for, or nil to hide them.
    init(window: NSWindow, tap: InputEventTap, clock: any Clock<Duration> = ContinuousClock(),
         isFront: @escaping @MainActor (NSWindow) -> Bool = WindowScopedShortcutHintModifierMonitor.isFrontWindow,
         keepsHints: @escaping (NSEvent) -> Bool = { _ in false },
         changed: @escaping (NSEvent.ModifierFlags?) -> Void) {
        self.window = window
        self.tap = tap
        self.clock = clock
        self.isFront = isFront
        self.keepsHints = keepsHints
        self.changed = changed
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != self.enabled else { return }
        self.enabled = enabled
        if enabled { start() } else { stop() }
    }

    /// Whether `window` is the active app's key window (a Chromium page window counts as its cmux window).
    static func isFrontWindow(_ window: NSWindow) -> Bool {
        NSApp.isActive && CmuxApplication.accessibilityWindow(for: NSApp.keyWindow) === window
    }

    private var eligible: Bool {
        guard enabled, let window else { return false }
        return isFront(window)
    }

    private func start() {
        guard let window else { return }
        subscription = tap.subscribe(class: [.flags, .key, .button], window: .window(window)) { [weak self] event in
            self?.observe(event)
        }
        for (name, object) in [(NSWindow.didResignKeyNotification, window as AnyObject?),
                               (NSApplication.didResignActiveNotification, nil)] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.holdLeftWindow() }
            })
        }
    }

    /// One event of this window from the tap: a modifier change, a key-down or a mouse-down.
    func observe(_ event: NSEvent) {
        switch event.type {
        case .flagsChanged:
            receive(event)
        case .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown:
            guard eligible else { return }
            // A mouse-down (Option-click) always hides; a pane-navigation key keeps the chips up.
            keyDown(keepsHints: event.type == .keyDown && keepsHints(event))
        default:
            break
        }
    }

    func receive(_ event: NSEvent) {
        guard event.type == .flagsChanged else { return }
        let flags = event.modifierFlags
        currentFlags = flags
        hide()
        // Reset suppression when the modifier is released; a Cmd, Ctrl or Option set arms the delay.
        _ = policy.update(flags: flags, eligible: eligible, elapsed: .zero)
        guard eligible, ShortcutHintModifierPolicy.armed(flags) != nil else { return }
        pending = Task { [weak self, clock] in
            // wakeup-allow: one cancellable, injected-clock 0.30s intentional hold deadline; never polling.
            do { try await clock.sleep(for: ShortcutHintModifierPolicy.intentionalHoldDelay) } catch { return }
            guard !Task.isCancelled, let self else { return }
            pending = nil
            let current = currentFlags
            if policy.update(flags: current, eligible: eligible, elapsed: ShortcutHintModifierPolicy.intentionalHoldDelay),
               let armed = ShortcutHintModifierPolicy.armed(current) {
                show(armed)
                #if DEBUG || CMUX_BENCH_HOOKS
                capture.finish(true)
                #endif
            }
        }
    }

    /// A key or click in the window: hides and suppresses until release, unless `keepsHints`
    /// (a pane-navigation key while the modifier stays held: shown chips stay, a pending hold still arms).
    func keyDown(keepsHints: Bool = false) {
        policy.keyDown(keepsHints: keepsHints)
        if !keepsHints { hide() }
    }

    #if DEBUG || CMUX_BENCH_HOOKS
    func debugHold(_ flags: NSEvent.ModifierFlags, window: NSWindow) async -> Bool {
        guard eligible, let event = debugEvent(flags, window: window) else { return false }
        if flags.isEmpty {
            receive(event)
            capture.finish(false)
            return true
        }
        return await capture.wait { receive(event) }
    }
    #endif

    private func show(_ held: NSEvent.ModifierFlags) {
        showing = true
        tap.setFlag(.hintsShowing, true)
        changed(held)
    }

    private func hide() {
        pending?.cancel()
        pending = nil
        // A key typed with no hint up does no hint work: only shown hints are taken down.
        guard showing else { return }
        showing = false
        tap.setFlag(.hintsShowing, false)
        changed(nil)
    }

    /// The window resigned key or the app resigned active: the hold's modifier changes now go to
    /// another window or app, so this window forgets the hold (its release would not reach it).
    private func holdLeftWindow() {
        hide()
        policy = ShortcutHintModifierPolicy()
        currentFlags = []
    }

    func stop() {
        holdLeftWindow()
        #if DEBUG
        capture.finish(false)
        #endif
        subscription?.cancel()
        subscription = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }
}
