public import AppKit
import CmuxNextCompat
import CmuxNextRemoteView
public import Observation
import os

/// "Send System Shortcuts to the Remote Mac" (`macScreen.systemShortcuts`): drives the session
/// event tap that runs in the Screen Sharing helper (``MacScreenShortcutTap``,
/// `cmux-screen-sharing __shortcut-tap`), so the Accessibility it needs is the helper's, the
/// same grant Mac Screen sharing and Computer Use use, and never cmux's own: turning it on in
/// System Settings never relaunches cmux. The helper process runs while the setting is on, the
/// helper holds Accessibility and a Mac Screen tab is connected (a fresh process each time, so
/// it always sees the current grant). It takes keys only while a Mac Screen tab's connected
/// screen has the keyboard, its window is key and cmux is the active app
/// (`RemoteSystemShortcuts.installs`). Any change that can end one of those (focus, the release
/// chord, a tab hidden or closed, the session's phase, a window or the app losing focus, the
/// setting) tells the helper at once.
///
/// Precedence while it holds: the system list (cmux-rd-host `shortcut_tap::takes`) goes to the
/// other Mac even where it is a cmux binding (Cmd-W, Cmd-Q); every other chord keeps the capture
/// view's rule, so the rest of cmux's shortcuts stay here, and Control-Option-Escape always
/// releases the keyboard. Secure Event Input hides keys from taps: the chords then act on this
/// Mac, as without the setting. No private API: no global hot key mode.
@Observable
public final class MacScreenSystemShortcuts {
    /// The setting; the app feeds it from cmux.json.
    public var enabled = false {
        didSet {
            guard enabled != oldValue else { return }
            if enabled { refreshAccessibility() } else { update() }
        }
    }
    /// The Screen Sharing helper holds Accessibility (its grant, read by ``MacScreenShareHost``).
    public var accessibilityGranted: Bool { host.accessibilityGranted }
    /// The helper's tap is taking the system list now.
    public private(set) var tapInstalled = false
    /// Writes the setting (the toolbar's menu item); the app fills it in.
    @ObservationIgnored public var setEnabled: (Bool) -> Void = { _ in }
    /// App state; tests replace it.
    @ObservationIgnored public var isAppActive: () -> Bool = { NSApp.isActive }
    /// Also run when the app becomes active (cmux Remote's report of the app's own grants).
    @ObservationIgnored var onAppActive: () -> Void = {}
    /// The panes that may hold the keyboard.
    @ObservationIgnored var panes: () -> [MacScreenPane] = { [] }
    /// Starts one tap process in the helper; throws when this build has no helper or its copy
    /// could not be staged. Tests replace it.
    @ObservationIgnored var launch: (MacScreenShortcutTap) async throws -> Void
    @ObservationIgnored private var tap: MacScreenShortcutTap?
    /// The surface the helper's keys go to (the one holding when it took them).
    @ObservationIgnored private weak var holder: RemoteInputSurface?
    /// The helper refused or could not start the tap: no new one until the grant is read again.
    @ObservationIgnored private var refused = false
    @ObservationIgnored private let host: MacScreenShareHost
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    @ObservationIgnored private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "mac-screen-shortcuts")

    init(host: MacScreenShareHost) {
        self.host = host
        launch = { [host] tap in
            guard let helper = await host.screenSharingHelper() else { throw CocoaError(.fileNoSuchFile) }
            guard let executable = await helper.executable() else { throw MacScreenHelper.NotStaged(helper: helper.name) }
            try tap.start { stdin, stdout, stderr in
                try MacScreenHelper.spawn(executable, [MacScreenShortcutTap.mode], stdin: stdin, stdout: stdout, stderr: stderr)
            }
        }
    }

    /// At launch: follows app activation, every window's key state, and the helper's grant.
    func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers = [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification].map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                let active = notification.name == NSApplication.didBecomeActiveNotification
                MainActor.assumeIsolated { // main-proof: observer on queue: .main
                    if active { self?.refused = false; self?.onAppActive() }
                    self?.update()
                }
            }
        } + [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification].map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.update() } // main-proof: observer on queue: .main
            }
        }
        // task-owner: app-lifetime observation of the helper's grant, made once at launch; holds this weakly
        Task { [weak self, host] in
            for await _ in ObservationStream({ host.accessibilityGranted }) {
                self?.refused = false
                self?.update()
            }
        }
    }

    /// macOS's Accessibility prompt for the Screen Sharing helper (System Settings when macOS no
    /// longer prompts). The tap runs in the helper, so the grant is the helper's, never cmux's.
    public func requestAccessibility() {
        host.requestAccessibility()
    }

    /// The helper's grant may have changed (the page appeared, a debug read): try the tap again.
    func refreshAccessibility() {
        refused = false
        update()
    }

    /// Starts, tells or ends the helper's tap to match the conditions now.
    func update() {
        let surface = target()
        guard runs() else {
            tap?.stop()
            tap = nil
            holder = nil
            tapInstalled = false
            return
        }
        let tap = tap ?? startTap()
        // A key the helper took just before it let go still reaches the surface that held.
        if let surface { holder = surface }
        tap.send(surface.map { .hold(release: $0.releaseChord) } ?? .letGo)
        tapInstalled = surface != nil
    }

    /// Whether the toggle is on but cannot work yet (the helper has no Accessibility).
    public var needsAccessibility: Bool { enabled && !accessibilityGranted }

    /// Whether the helper's tap process runs: the setting, the helper's grant, and a connected tab.
    private func runs() -> Bool {
        enabled && accessibilityGranted && !refused && panes().contains { $0.model.isLive }
    }

    private func startTap() -> MacScreenShortcutTap {
        let tap = MacScreenShortcutTap()
        tap.onKey = { [weak self] key in self?.holder?.sendSystemKey(key) }
        tap.onEnd = { [weak self, weak tap] reason in
            guard let self, let tap, self.tap === tap else { return }
            self.logger.error("the Screen Sharing helper's shortcut tap ended: \(reason ?? "exited", privacy: .public)")
            self.ended()
            // The helper may have lost Accessibility: read its grants again (no prompt).
            Task { [host = self.host] in await host.refreshPermissions() }
        }
        self.tap = tap
        let launch = launch
        // task-owner: one helper start; a failure ends this tap and waits for the grant to be read again
        Task { [weak self, weak tap] in
            guard let tap else { return }
            do { try await launch(tap) } catch {
                guard let self, self.tap === tap else { return }
                self.logger.error("the Screen Sharing helper's shortcut tap did not start: \(String(describing: error), privacy: .public)")
                self.ended()
            }
        }
        return tap
    }

    private func ended() {
        tap?.stop()
        tap = nil
        holder = nil
        tapInstalled = false
        refused = true
    }

    /// The surface the tap serves under the conditions now, or nil when it must let every key pass.
    private func target() -> RemoteInputSurface? {
        let holding = panes().filter { $0.view.input.hasKeyboard }
        let pane = holding.first { $0.view.window?.isKeyWindow == true } ?? holding.first
        let conditions = RemoteSystemShortcuts.Conditions(
            setting: enabled, accessibility: accessibilityGranted && !refused, hasKeyboard: pane != nil, live: pane?.model.isLive ?? false,
            windowKey: pane?.view.window?.isKeyWindow ?? false, appActive: isAppActive())
        guard RemoteSystemShortcuts().installs(conditions) else { return nil }
        return pane?.view.input
    }
}
