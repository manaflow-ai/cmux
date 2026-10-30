public import AppKit
public import CmuxNextActions
import CmuxNextDesign

/// Background mode (Leo 2026-10-13, cx-ghagp): with no cmux window open the
/// app keeps running, since terminals and agents live in their daemons, as a
/// menu bar app. The activation policy drops to accessory (no Dock icon, not
/// in Cmd-Tab) and a menu bar item takes the Dock icon's place: the cmux menu
/// bar item (``MenuBarExtra``) when it is on, else this mode's own: Show cmux,
/// New Window, Settings, Quit. Any window opening (Dock reopen from Finder or
/// Spotlight, the menu bar item, a notification, the CLI, a URL, Settings)
/// makes the app regular again before the window is ordered in, then
/// activates it, so the window comes up in front with the keys and the menu
/// bar. Panels (About, Start Agent, sign-in sheets) show without leaving the
/// mode, like any menu bar app's.
///
/// The App's window manager owns one and supplies `mayEnter`: these are the
/// process's own services (`AppProcessRoot`), so services a test builds leave
/// the test process alone; no window is open; cmux is not quitting; and
/// `app.hideDockIconWithoutWindows` is on (false keeps the old behavior:
/// regular with no window).
@MainActor
public final class BackgroundActivation {
    private let registry: ActionRegistry
    private let icon: NSImage
    private let mayEnter: @MainActor () -> Bool
    /// The cmux menu bar item is shown (`app.showMenuBarIcon`, ``MenuBarExtra``): background mode
    /// uses it instead of adding a second item.
    private let menuBarItemShown: @MainActor () -> Bool
    /// The menu bar item while in background mode, nil while ``MenuBarExtra``'s stands in.
    private var item: NSStatusItem?
    private var entered = false
    private var settlePending = false

    /// `icon` is the menu bar item's image; its accessibility label is the app's name.
    /// `menuBarItemShown` says whether the cmux menu bar item already gives the way back.
    public init(registry: ActionRegistry, icon: NSImage, mayEnter: @escaping @MainActor () -> Bool,
                menuBarItemShown: @escaping @MainActor () -> Bool = { false }) {
        self.registry = registry
        self.icon = icon
        self.mayEnter = mayEnter
        self.menuBarItemShown = menuBarItemShown
        icon.accessibilityDescription = NSRunningApplication.current.localizedName
    }

    /// In background mode: accessory, with a menu bar item (its own or ``MenuBarExtra``'s).
    public var isBackground: Bool { entered }

    /// The cmux menu bar item came or went: in background mode, show this mode's own item exactly
    /// while that one is off, so a way back to cmux stays in the menu bar.
    public func menuBarItemDidChange() {
        guard entered else { return }
        if menuBarItemShown() { hideItem() } else if item == nil { showItem() }
    }

    /// A window closed: once nothing replaces it this turn (a tear-off, the
    /// launch window handing over), no open window means background mode.
    public func windowsDidChange() {
        guard !settlePending else { return }
        settlePending = true
        Task { @MainActor [weak self] in self?.settle() }
    }

    /// A shell window is about to be ordered in: leave background mode first,
    /// so it comes in with the Dock icon and the menu bar. `activates` false
    /// for a window opened behind (automation without view change).
    public func windowWillAppear(activates: Bool) {
        guard isBackground else { return }
        entered = false
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
        guard !isBackground, mayEnter(), NSApp.activationPolicy() == .regular else { return }
        NSApp.setActivationPolicy(.accessory)
        entered = true
        if !menuBarItemShown() { showItem() }
    }

    private func showItem() {
        // cmux-classic's item: variable length, image only, scaled down proportionally.
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.imageScaling = .scaleProportionallyDown
        statusItem.button?.image = icon
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
