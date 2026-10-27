import AppKit
import CmuxNextInput
import CmuxNextWakeups

/// Watches only the host window's intentional Command/Control/Option holds; a key or a click (Option-click) hides and suppresses. It never consumes input.
///
/// While hints are enabled, observe subscriptions on the app's input tap (p04-input.md 3 (A)) hear this
/// window's modifier changes and, only while a modifier is held here (an O(1) `while:` predicate), its
/// key-downs and the app's mouse-downs: a plain key does no hint work. Observers run before the key
/// router, so a key the router consumes still hides the hints; this is the only key-down entrypoint.
/// A mouse-down in any window (a Cmd-click on a background window, an Option-click in a panel) hides
/// while this window is in front, as AppKit's app-wide local monitor did. While hints show, the tap's
/// `hintsShowing` flag is set, so per-key work elsewhere checks it in O(1).
@MainActor
final class WindowScopedShortcutHintModifierMonitor {
    private weak var window: NSWindow?
    private let tap: InputEventTap
    /// The window's own resign-key notice and the app's resign-active notice.
    private let windowEvents: WindowEvents
    private let appEvents: AppEvents
    /// The intentional-hold deadline of one modifier press, in the visible class; its release or a key cancels it.
    private let holdDeadline: MainDeadline
    private let changed: (NSEvent.ModifierFlags?) -> Void
    private let keepsHints: (NSEvent) -> Bool
    private let isFront: @MainActor (NSWindow) -> Bool
    private var policy = ShortcutHintModifierPolicy()
    private var subscriptions: [InputSubscription] = []
    /// The policy's `held`, read by the key and click subscriptions' predicate without a weak load.
    private let hold = Hold()
    private var leaveSubscriptions: [EventSubscription] = []
    private var enabled = false
    /// Hints show in this window now; the tap's `hintsShowing` flag is set while it is true.
    private(set) var showing = false
    private var currentFlags: NSEvent.ModifierFlags = []
    #if DEBUG || CMUX_BENCH_HOOKS
    private let capture = ShortcutHintCaptureWaiter()
    #endif

    /// - Parameters:
    ///   - tap: The app's input tap.
    ///   - deadlines: The app's deadline placer (`AppServices.mainDeadlines`): the hold deadline is one of its wakes.
    ///   - events: The app's notices (`AppServices.appEvents`): its resign-active notice.
    ///   - windowEvents: The window's notices (default `WindowEvents.of(window)`): its resign-key notice.
    ///   - isFront: Whether the window is the one a hold shows hints in (the active app's key window).
    ///   - keepsHints: Whether a key-down leaves the hints up (a pane-navigation key); others hide them until release.
    ///   - changed: The held set to show hints for, or nil to hide them.
    init(window: NSWindow, tap: InputEventTap, deadlines: MainDeadlineScheduler, events: AppEvents, windowEvents: WindowEvents? = nil,
         isFront: @escaping @MainActor (NSWindow) -> Bool = WindowScopedShortcutHintModifierMonitor.isFrontWindow,
         keepsHints: @escaping (NSEvent) -> Bool = { _ in false },
         changed: @escaping (NSEvent.ModifierFlags?) -> Void) {
        self.window = window
        self.tap = tap
        self.windowEvents = windowEvents ?? WindowEvents.of(window)
        appEvents = events
        holdDeadline = MainDeadline(owner: "ShortcutHint.intentionalHold", workClass: .visible, scheduler: deadlines)
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
        let held: @MainActor () -> Bool = { [hold] in hold.active }
        let deliver: @MainActor (NSEvent) -> Void = { [weak self] event in self?.observe(event) }
        subscriptions = [
            tap.subscribe(class: .flags, window: .window(window), handler: deliver),
            tap.subscribe(class: .key, window: .window(window), while: held, handler: deliver),
            tap.subscribe(class: .button, window: .anyWindow, while: held, handler: deliver),
        ]
        // The hold's modifier changes go to another window or app now: forget it in the notice's own turn.
        let owner = "ShortcutHint.holdLeftWindow"
        leaveSubscriptions = [
            windowEvents.subscribe(NSWindow.didResignKeyNotification, owner: owner) { [weak self] in self?.holdLeftWindow() },
            appEvents.subscribe(NSApplication.didResignActiveNotification, owner: owner) { [weak self] in self?.holdLeftWindow() },
        ]
    }

    /// One event from the tap: this window's modifier change or key-down, or any window's mouse-down.
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
        hold.active = policy.held
        guard eligible, ShortcutHintModifierPolicy.armed(flags) != nil else { return }
        holdDeadline.schedule(after: ShortcutHintModifierPolicy.intentionalHoldDelay) { [weak self] in
            self?.holdElapsed()
        }
    }

    /// The modifier stayed down for the intentional hold: the hints show when the policy agrees.
    private func holdElapsed() {
        let current = currentFlags
        if policy.update(flags: current, eligible: eligible, elapsed: ShortcutHintModifierPolicy.intentionalHoldDelay),
           let armed = ShortcutHintModifierPolicy.armed(current) {
            show(armed)
            #if DEBUG || CMUX_BENCH_HOOKS
            capture.finish(true)
            #endif
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
        holdDeadline.cancel()
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
        hold.active = false
        currentFlags = []
    }

    func stop() {
        holdLeftWindow()
        #if DEBUG
        capture.finish(false)
        #endif
        subscriptions.forEach { $0.cancel() }
        subscriptions.removeAll()
        leaveSubscriptions.forEach { $0.cancel() }
        leaveSubscriptions.removeAll()
    }

    /// Whether a modifier is held in this window, shared with the subscriptions' predicate.
    private final class Hold {
        var active = false
    }
}
