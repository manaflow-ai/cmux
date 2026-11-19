public import AppKit
public import CmuxNextActions
import CmuxNextCompat
import CmuxNextDesign

/// The cmux item in the macOS menu bar (`app.showMenuBarIcon`, on by default; user 2026-10-27,
/// after Raycast's): a template cmux icon, with a dot while an agent acts through Computer Use
/// (``computerUseActive``), whose menu (``MenuBarMenuSpec``) shows Computer Use, the
/// Unread and Running chats, opens cmux, shows the account and the agents that work or wait, and
/// offers help, cmux's community, updates, logs and Quit. Every fixed row runs a registry action.
///
/// The menu is built as it opens (`menuNeedsUpdate`) from ``MenuBarExtraHost``, so nothing is read
/// or observed while it is closed. The App's services own one; it shows while the setting is on.
/// Background mode (``BackgroundActivation``) uses this item instead of adding a second one.
@MainActor
public final class MenuBarExtra: NSObject, NSMenuDelegate {
    private let registry: ActionRegistry
    private let icon: NSImage
    /// The icon with its Computer Use dot (``MenuBarIcon/image(badged:)``); nil draws no dot.
    private let badgedIcon: NSImage?
    private weak var host: (any MenuBarExtraHost)?
    private var item: NSStatusItem?
    private var following: Task<Void, Never>?
    /// The chat rows' target (a row holds it weakly).
    private lazy var commands = MenuBarCommandTarget { [weak self] command in self?.run(command) }
    /// The open menu (its Computer Use row follows the worker's sessions), nil while closed.
    private weak var openMenu: NSMenu?
    /// An agent acts through Computer Use now (it acted within the last 2 s): the icon shows its dot.
    /// Set by the App from the daemon's `computer-use-activity`; swapping the image is the whole cost.
    public var computerUseActive = false {
        didSet {
            guard computerUseActive != oldValue else { return }
            applyIcon()
        }
    }
    /// What keeps the Mac awake now, nil while nothing does: `KeepAwakeService` sets it each time its
    /// hold starts, ends or changes why, and the menu's Keeping Mac awake line reads it on open.
    public var keepingAwake: MenuBarMenuState.KeepingAwake?

    /// - Parameters:
    ///   - registry: Runs every row.
    ///   - icon: The item's image (``MenuBarIcon``, cmux-classic's); drawn as a template (monochrome, follows the menu bar).
    ///   - badgedIcon: The same with the Computer Use dot; nil never shows one.
    ///   - host: What the menu reads as it opens; held weakly.
    public init(registry: ActionRegistry, icon: NSImage, badgedIcon: NSImage? = nil, host: any MenuBarExtraHost) {
        self.registry = registry
        self.icon = icon
        self.badgedIcon = badgedIcon
        self.host = host
        icon.isTemplate = true
        icon.accessibilityDescription = NSRunningApplication.current.localizedName
        badgedIcon?.isTemplate = true
        badgedIcon?.accessibilityDescription = MenuBarExtraStrings.computerUseActive(NSRunningApplication.current.localizedName ?? "cmux")
        super.init()
    }

    /// The image the item shows now: the dot while an agent acts.
    private var currentIcon: NSImage { computerUseActive ? badgedIcon ?? icon : icon }

    private func applyIcon() {
        item?.button?.image = currentIcon
    }

    /// The worker's sessions changed: an open menu's Computer Use row shows them in place (no row
    /// moves); a closed menu reads them when it opens.
    public func computerUseSessionsChanged() {
        guard let menu = openMenu, let host, host.menuBarComputerUseAvailable else { return }
        MenuBarMenuBuilder(registry: registry).updateComputerUse(in: menu, MenuBarMenuState.ComputerUse(sessions: host.menuBarComputerUseSessions),
                                                                 commands: commands)
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
        statusItem.button?.image = currentIcon
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
        let state = state()
        MenuBarMenuBuilder(registry: registry).fill(menu, state: state, avatar: host?.menuBarAvatar, commands: commands,
                                                    chatImage: { [weak host] in host?.menuBarChatImage($0) })
    }

    public func menuWillOpen(_ menu: NSMenu) { openMenu = menu }

    public func menuDidClose(_ menu: NSMenu) { openMenu = nil }

    /// A chat row opens its chat in front.
    private func run(_ command: MenuBarMenuSpec.Command) {
        guard let host else { return }
        switch command {
        case .openChat(let id):
            WindowActivation.activateApp()
            host.menuBarOpenChat(id)
        case .computerUseResume(let session):
            host.menuBarResumeComputerUse(session)
        case .computerUseShowCursor(let session):
            host.menuBarShowComputerUseCursor(session)
        }
    }

    /// What the menu shows now (also what a test or the CLI's dump would read).
    public func state() -> MenuBarMenuState {
        guard let host else { return MenuBarMenuState() }
        return MenuBarMenuState(account: host.menuBarAccount, agentsWorking: host.menuBarAgentsWorking,
                                agentsNeedingInput: host.menuBarAgentsNeedingInput, updateReady: host.menuBarUpdateReady,
                                showsGlobalKey: host.menuBarShowsGlobalKey,
                                computerUse: host.menuBarComputerUseAvailable ? .init(sessions: host.menuBarComputerUseSessions) : nil,
                                unread: .init(host.menuBarUnread), running: .init(host.menuBarRunning),
                                keepingAwake: keepingAwake)
    }
}
