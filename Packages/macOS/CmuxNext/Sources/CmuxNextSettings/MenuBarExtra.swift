public import AppKit
public import CmuxNextActions
import CmuxNextCompat

/// The cmux item in the macOS menu bar (`app.showMenuBarIcon`, on by default; user 2026-10-27,
/// after Raycast's): a template cmux icon whose menu (``MenuBarMenuSpec``) opens cmux, shows the
/// account and the agents that work or wait, and offers help, cmux's community, updates, logs and
/// Quit. Every row runs a registry action.
///
/// The menu is built as it opens (`menuNeedsUpdate`) from ``MenuBarExtraHost``, so nothing is read
/// or observed while it is closed. The App's services own one; it shows while the setting is on.
/// Background mode (``BackgroundActivation``) uses this item instead of adding a second one.
@MainActor
public final class MenuBarExtra: NSObject, NSMenuDelegate {
    private let registry: ActionRegistry
    private let icon: NSImage
    private weak var host: (any MenuBarExtraHost)?
    private var item: NSStatusItem?
    private var following: Task<Void, Never>?

    /// - Parameters:
    ///   - registry: Runs every row.
    ///   - icon: The item's image (``MenuBarIcon``, cmux-classic's); drawn as a template (monochrome, follows the menu bar).
    ///   - host: What the menu reads as it opens; held weakly.
    public init(registry: ActionRegistry, icon: NSImage, host: any MenuBarExtraHost) {
        self.registry = registry
        self.icon = icon
        self.host = host
        icon.isTemplate = true
        icon.accessibilityDescription = NSRunningApplication.current.localizedName
        super.init()
    }

    /// The item is in the menu bar.
    public var isShown: Bool { item != nil }

    /// Shows the item while `app.showMenuBarIcon` is on, from the first load on, and tells
    /// `background` each time so background mode keeps exactly one way back in the menu bar.
    /// Event-driven (Observation): no polling, nothing runs while the setting stays put.
    public func follow(_ settings: SettingsController, background: BackgroundActivation) {
        following?.cancel()
        // task-owner: replaced by the next follow; ends with this item (the App's services)
        following = Task { [weak self, weak settings, weak background] in
            guard let settings else { return }
            await settings.waitForLoad(atLeast: 1)
            for await shown in ObservationStream({ settings.snapshot.showMenuBarIcon }) {
                guard let self else { return }
                self.setShown(shown)
                background?.menuBarItemDidChange()
            }
        }
    }

    /// Puts the item in the menu bar or takes it out (idempotent).
    public func setShown(_ shown: Bool) {
        if shown { show() } else { hide() }
    }

    private func show() {
        guard item == nil else { return }
        // cmux-classic's item: variable length, image only, scaled down proportionally.
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.imageScaling = .scaleProportionallyDown
        statusItem.button?.image = icon
        statusItem.button?.identifier = NSUserInterfaceItemIdentifier("cmux.menuBarExtra")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        item = statusItem
    }

    private func hide() {
        if let item { NSStatusBar.system.removeStatusItem(item) }
        item = nil
    }

    /// The menu is about to open: its rows for the state now.
    public func menuNeedsUpdate(_ menu: NSMenu) {
        MenuBarMenuBuilder(registry: registry).fill(menu, state: state(), avatar: host?.menuBarAvatar)
    }

    /// What the menu shows now (also what a test or the CLI's dump would read).
    public func state() -> MenuBarMenuState {
        guard let host else { return MenuBarMenuState() }
        return MenuBarMenuState(account: host.menuBarAccount, agentsWorking: host.menuBarAgentsWorking,
                                agentsNeedingInput: host.menuBarAgentsNeedingInput, updateReady: host.menuBarUpdateReady,
                                showsGlobalKey: host.menuBarShowsGlobalKey)
    }
}
