import AppKit

/// Watches only the host window's intentional Command/Control holds. It never consumes input.
@MainActor
final class WindowScopedShortcutHintModifierMonitor {
    private weak var window: NSWindow?
    private let clock: any Clock<Duration>
    private let changed: (NSEvent.ModifierFlags?) -> Void
    private var policy = ShortcutHintModifierPolicy()
    private var flagsMonitor: Any?
    private var keyMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var pending: Task<Void, Never>?
    private var enabled = false

    init(window: NSWindow, clock: any Clock<Duration> = ContinuousClock(),
         changed: @escaping (NSEvent.ModifierFlags?) -> Void) {
        self.window = window
        self.clock = clock
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
            self?.update(event.modifierFlags)
            return event
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, eligible else { return event }
            keyDown()
            return event
        }
        for (name, object) in [(NSWindow.didResignKeyNotification, window as AnyObject?),
                               (NSApplication.didResignActiveNotification, nil)] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.hide() }
            })
        }
    }

    private func update(_ flags: NSEvent.ModifierFlags) {
        hide()
        // Reset suppression when the modifier is released; only bare Cmd/Ctrl arms the delay.
        _ = policy.update(flags: flags, eligible: eligible, elapsed: .zero)
        let modifiers = flags.intersection([.command, .control, .shift, .option])
        guard eligible, modifiers == .command || modifiers == .control else { return }
        pending = Task { [weak self, clock] in
            do { try await clock.sleep(for: ShortcutHintModifierPolicy.intentionalHoldDelay) } catch { return }
            guard !Task.isCancelled, let self else { return }
            pending = nil
            let current = NSEvent.modifierFlags
            if policy.update(flags: current, eligible: eligible, elapsed: ShortcutHintModifierPolicy.intentionalHoldDelay) {
                changed(current.intersection([.command, .control]))
            }
        }
    }

    func keyDown() {
        policy.keyDown()
        hide()
    }

    private func hide() {
        pending?.cancel()
        pending = nil
        changed(nil)
    }

    func stop() {
        hide()
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        flagsMonitor = nil
        keyMonitor = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }
}
