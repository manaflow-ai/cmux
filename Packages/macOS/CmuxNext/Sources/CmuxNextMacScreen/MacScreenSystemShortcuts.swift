public import AppKit
import ApplicationServices
import CmuxNextRemoteView
public import Observation

/// "Send System Shortcuts to the Remote Mac" (`macScreen.systemShortcuts`):
/// owns the app's one `RemoteSystemShortcutTap` and keeps it installed
/// exactly while the setting is on, cmux has Accessibility, a Mac Screen
/// tab's connected screen has the keyboard, its window is key and cmux is
/// the active app (`RemoteSystemShortcuts.installs`). Any change that can
/// end one of those (focus, the release chord, a tab hidden or closed, the
/// session's phase, a window or the app losing focus, the setting) updates
/// it at once; the tap also asks on every key.
///
/// Precedence while it runs: the system list (`RemoteSystemShortcuts.takes`)
/// goes to the other Mac even where it is a cmux binding (Cmd-W, Cmd-Q);
/// every other chord keeps the capture view's rule, so the rest of cmux's
/// shortcuts stay here, and Control-Option-Escape always releases the
/// keyboard. Secure Event Input hides keys from taps: the chords then act on
/// this Mac, as without the setting. No private API: no global hot key mode.
@Observable
public final class MacScreenSystemShortcuts {
    /// The setting; the app feeds it from cmux.json.
    public var enabled = false {
        didSet {
            guard enabled != oldValue else { return }
            if enabled { refreshAccessibility() }
            update()
        }
    }
    /// cmux is trusted for Accessibility (rechecked when the app becomes active).
    public private(set) var accessibilityGranted = false
    /// The tap is installed now.
    public private(set) var tapInstalled = false
    /// Writes the setting (the toolbar's menu item); the app fills it in.
    @ObservationIgnored public var setEnabled: (Bool) -> Void = { _ in }
    /// Permission and app state checks; tests replace them.
    @ObservationIgnored public var checkAccessibility: () -> Bool = { AXIsProcessTrusted() }
    @ObservationIgnored public var isAppActive: () -> Bool = { NSApp.isActive }
    /// The panes that may hold the keyboard.
    @ObservationIgnored var panes: () -> [MacScreenPane] = { [] }
    @ObservationIgnored private let tap = RemoteSystemShortcutTap()
    @ObservationIgnored private let policy = RemoteSystemShortcuts()
    @ObservationIgnored private let host: MacScreenShareHost
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []

    init(host: MacScreenShareHost) {
        self.host = host
        tap.stillHolds = { [weak self] in self?.target() != nil }
        tap.onRemoved = { [weak self] in self?.tapInstalled = false }
    }

    /// At launch: follows app activation (rechecking Accessibility after
    /// System Settings) and every window's key state.
    func start() {
        refreshAccessibility()
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers = [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification].map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                let active = notification.name == NSApplication.didBecomeActiveNotification
                MainActor.assumeIsolated { // main-proof: observer on queue: .main
                    if active { self?.refreshAccessibility() }
                    self?.update()
                }
            }
        } + [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification].map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.update() } // main-proof: observer on queue: .main
            }
        }
    }

    /// Asks macOS for Accessibility; when it does not show its prompt, opens
    /// System Settings > Privacy & Security > Accessibility in the background.
    public func requestAccessibility() {
        host.requestAccessibility()
        refreshAccessibility()
    }

    func refreshAccessibility() {
        let granted = checkAccessibility()
        guard granted != accessibilityGranted else { return }
        accessibilityGranted = granted
        update()
    }

    /// Installs or removes the tap to match the conditions now.
    func update() {
        if let surface = target() {
            tapInstalled = tap.install(for: surface)
        } else if tap.isInstalled {
            tap.remove()
        } else {
            tapInstalled = false
        }
    }

    /// Whether the toggle is on but cannot work yet (no Accessibility).
    public var needsAccessibility: Bool { enabled && !accessibilityGranted }

    /// The surface the tap serves under the conditions now, or nil when it must not run.
    private func target() -> RemoteInputSurface? {
        let holding = panes().filter { $0.view.input.hasKeyboard }
        let pane = holding.first { $0.view.window?.isKeyWindow == true } ?? holding.first
        let conditions = RemoteSystemShortcuts.Conditions(
            setting: enabled, accessibility: accessibilityGranted, hasKeyboard: pane != nil, live: pane?.model.isLive ?? false,
            windowKey: pane?.view.window?.isKeyWindow ?? false, appActive: isAppActive())
        guard policy.installs(conditions) else { return nil }
        return pane?.view.input
    }
}
