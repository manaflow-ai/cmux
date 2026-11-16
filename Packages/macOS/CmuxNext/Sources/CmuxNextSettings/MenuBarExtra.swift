public import AppKit
public import CmuxNextActions
import CmuxNextCompat
import CmuxNextDesign

/// The cmux item in the macOS menu bar (`app.showMenuBarIcon`, on by default; user 2026-10-27,
/// after Raycast's): a template cmux icon whose menu (``MenuBarMenuSpec``) shows Computer Use, the
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
    private weak var host: (any MenuBarExtraHost)?
    private var item: NSStatusItem?
    private var following: Task<Void, Never>?
    /// The chat and Computer Use rows' target (a row holds it weakly).
    private lazy var commands = MenuBarCommandTarget { [weak self] command in self?.run(command) }
    /// The Computer Use session the host named last: the row opens with it, then the host's
    /// answer to this opening updates the row in place.
    private var computerUseSession: MenuBarMenuState.ComputerUse.Session?
    /// The ask for this opening's session; one at a time.
    private var computerUseAsked: Task<Void, Never>?
    private var isOpen = false
    /// What keeps the Mac awake now, nil while nothing does: `KeepAwakeService` sets it each time its
    /// hold starts, ends or changes why, and the menu's Keeping Mac awake line reads it on open.
    public var keepingAwake: MenuBarMenuState.KeepingAwake?

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
        let state = state()
        MenuBarMenuBuilder(registry: registry).fill(menu, state: state, avatar: host?.menuBarAvatar, commands: commands,
                                                    chatImage: { [weak host] in host?.menuBarChatImage($0) })
        if state.computerUse != nil { askComputerUse(menu) }
    }

    public func menuWillOpen(_ menu: NSMenu) { isOpen = true }

    /// A closed menu drops its Computer Use question: its answer would update the next opening.
    public func menuDidClose(_ menu: NSMenu) {
        isOpen = false
        computerUseAsked?.cancel()
        computerUseAsked = nil
    }

    /// A chat row opens its chat in front; Take Over and Hand Back ask the CUA host, and a refusal
    /// says why as the registry's other refusals do.
    private func run(_ command: MenuBarMenuSpec.Command) {
        guard let host else { return }
        switch command {
        case .openChat(let id):
            WindowActivation.activateApp()
            host.menuBarOpenChat(id)
        case .takeOver(let id), .handBack(let id):
            let paused = if case .takeOver = command { true } else { false }
            // task-owner: one Take Over or Hand Back; ends with the host's answer (5 s deadline).
            Task { [registry] in
                do {
                    try await host.menuBarSetComputerUsePaused(id, paused)
                } catch {
                    registry.refuse(String(describing: error))
                }
            }
        }
    }

    /// Asks the CUA host for its newest session (one socket request per opening, dropped when
    /// it closes) and, when it differs from the one shown, rewrites the Computer Use row in place:
    /// the row is there either way, so no row moves.
    private func askComputerUse(_ menu: NSMenu) {
        guard computerUseAsked == nil, let host else { return }
        // task-owner: one per menu opening; ends with the host's answer (CuaSocketClient's 5 s deadline).
        computerUseAsked = Task { [weak self, weak menu] in
            let session = await host.menuBarComputerUseSession()
            guard let self, !Task.isCancelled else { return }
            self.computerUseAsked = nil
            guard session != self.computerUseSession else { return }
            self.computerUseSession = session
            guard self.isOpen, let menu else { return }
            MenuBarMenuBuilder(registry: self.registry).updateComputerUse(in: menu, MenuBarMenuState.ComputerUse(session: session),
                                                                          commands: self.commands)
        }
    }

    /// What the menu shows now (also what a test or the CLI's dump would read).
    public func state() -> MenuBarMenuState {
        guard let host else { return MenuBarMenuState() }
        return MenuBarMenuState(account: host.menuBarAccount, agentsWorking: host.menuBarAgentsWorking,
                                agentsNeedingInput: host.menuBarAgentsNeedingInput, updateReady: host.menuBarUpdateReady,
                                showsGlobalKey: host.menuBarShowsGlobalKey,
                                computerUse: host.menuBarComputerUseAvailable ? .init(session: computerUseSession) : nil,
                                unread: .init(host.menuBarUnread), running: .init(host.menuBarRunning),
                                keepingAwake: keepingAwake)
    }
}
