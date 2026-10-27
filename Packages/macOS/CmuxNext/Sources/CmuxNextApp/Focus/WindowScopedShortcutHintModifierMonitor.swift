import AppKit

/// Watches only the host window's intentional Command/Control/Option holds; a key or a click (Option-click) hides and suppresses. It never consumes input.
@MainActor
final class WindowScopedShortcutHintModifierMonitor {
    private weak var window: NSWindow?
    private let clock: any Clock<Duration>
    private let changed: (NSEvent.ModifierFlags?) -> Void
    private let keepsHints: (NSEvent) -> Bool
    private var policy = ShortcutHintModifierPolicy()
    private var flagsMonitor: Any?
    private var keyMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var pending: Task<Void, Never>?
    private var enabled = false
    private var currentFlags: NSEvent.ModifierFlags = []
    #if DEBUG || CMUX_BENCH_HOOKS
    private let capture = ShortcutHintCaptureWaiter()
    #endif

    /// - Parameters:
    ///   - keepsHints: Whether a key-down leaves the hints up (a pane-navigation key); others hide them until release.
    ///   - changed: The held set to show hints for, or nil to hide them.
    init(window: NSWindow, clock: any Clock<Duration> = ContinuousClock(),
         keepsHints: @escaping (NSEvent) -> Bool = { _ in false },
         changed: @escaping (NSEvent.ModifierFlags?) -> Void) {
        self.window = window
        self.clock = clock
        self.keepsHints = keepsHints
        self.changed = changed
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != self.enabled else { return }
        self.enabled = enabled
        if enabled { start() } else { stop() }
    }

    private var eligible: Bool { enabled && NSApp.isActive && CmuxApplication.accessibilityWindow(for: NSApp.keyWindow) === window }

    private func start() {
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.receive(event)
            return event
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            guard let self, eligible else { return event }
            // A mouse-down (Option-click) always hides; a pane-navigation key keeps the chips up.
            keyDown(keepsHints: event.type == .keyDown && keepsHints(event))
            return event
        }
        for (name, object) in [(NSWindow.didResignKeyNotification, window as AnyObject?),
                               (NSApplication.didResignActiveNotification, nil)] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.hide() }
            })
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
            if policy.update(flags: current, eligible: eligible, elapsed: ShortcutHintModifierPolicy.intentionalHoldDelay) {
                changed(ShortcutHintModifierPolicy.armed(current))
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

    private func hide() {
        pending?.cancel()
        pending = nil
        changed(nil)
    }

    func stop() {
        hide()
        #if DEBUG
        capture.finish(false)
        #endif
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        flagsMonitor = nil
        keyMonitor = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }
}
