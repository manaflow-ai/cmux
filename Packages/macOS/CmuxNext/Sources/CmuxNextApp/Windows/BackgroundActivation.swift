import AppKit
import CmuxNextActions
import CmuxNextDesign
import CmuxNextIcons
import CmuxNextSettings

/// Background mode (Leo 2026-10-13, cx-ghagp): with no cmux window open the
/// app keeps running, since terminals and agents live in their daemons, as a
/// menu bar app. The activation policy drops to accessory (no Dock icon, not
/// in Cmd-Tab) and a menu bar item takes the Dock icon's place: Show cmux,
/// New Window, Settings, Quit. Any window opening (Dock reopen from Finder or
/// Spotlight, the menu bar item, a notification, the CLI, a URL, Settings)
/// makes the app regular again before the window is ordered in, then
/// activates it, so the window comes up in front with the keys and the menu
/// bar. Panels (About, Start Agent, sign-in sheets) show without leaving the
/// mode, like any menu bar app's.
///
/// `app.hideDockIconWithoutWindows` false keeps the old behavior: regular
/// with no window. Only the process's own services (`AppProcessRoot`) drive
/// the policy, so services a test builds leave the test process alone.
@MainActor
final class BackgroundActivation {
    private weak var manager: WindowManager?
    /// The menu bar item while in background mode.
    private var item: NSStatusItem?
    private var settlePending = false

    init(manager: WindowManager) {
        self.manager = manager
    }

    /// In background mode: accessory, with the menu bar item.
    var isBackground: Bool { item != nil }

    private var drivesPolicy: Bool { manager.map { AppProcessRoot.shared.services === $0.services } ?? false }

    /// A window closed: once nothing replaces it this turn (a tear-off, the
    /// launch window handing over), no open window means background mode.
    func windowsDidChange() {
        guard drivesPolicy, !settlePending else { return }
        settlePending = true
        Task { @MainActor [weak self] in self?.settle() }
    }

    /// A shell window is about to be ordered in: leave background mode first,
    /// so it comes in with the Dock icon and the menu bar. `activates` false
    /// for a window opened behind (automation without view change).
    func windowWillAppear(activates: Bool) {
        guard isBackground else { return }
        hideItem()
        guard NSApp.activationPolicy() == .accessory else { return }
        let wasActive = NSApp.isActive
        NSApp.setActivationPolicy(.regular)
        guard activates, !WindowPlacement.noActivate else { return }
        guard wasActive else { return WindowActivation.activateApp() }
        // Active while accessory (a Finder or Spotlight reopen activates the
        // app first): AppKit keeps showing no menu bar for an app made regular
        // while active, until it is activated again.
        NSApp.deactivate()
        Task { @MainActor in WindowActivation.activateApp() }
    }

    private func settle() {
        settlePending = false
        guard let manager, drivesPolicy, !isBackground else { return }
        let enabled = manager.services.settings?.snapshot.hideDockIconWithoutWindows ?? CmuxConfigSnapshot.hideDockIconWithoutWindowsFallback
        guard enabled, !manager.isTerminating, !manager.services.quit.isQuitting, manager.controllers.isEmpty,
              NSApp.activationPolicy() == .regular else { return }
        NSApp.setActivationPolicy(.accessory)
        showItem()
    }

    private func showItem() {
        guard let registry = manager?.services.registry else { return }
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            let image = NSImage.icon(.appCmux, size: 16)
            image.accessibilityDescription = Strings.appName
            button.image = image
        }
        let menu = NSMenu()
        for id: ActionID in ["showMainWindow", "newWindow", "openSettings"] {
            if let entry = registry.makeMenuItem(for: id) { menu.addItem(entry) }
        }
        menu.addItem(.separator())
        if let quit = registry.makeMenuItem(for: "quit") { menu.addItem(quit) }
        statusItem.menu = menu
        item = statusItem
    }

    private func hideItem() {
        if let item { NSStatusBar.system.removeStatusItem(item) }
        item = nil
    }
}
