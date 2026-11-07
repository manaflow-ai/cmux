import AppKit
import CmuxNextDesign

/// The pinned extension actions of the bound tab and the Extensions (puzzle) button, which every
/// Chromium tab shows, as Chrome does (Lawrence 2026-10-18: "show extensions there by default").
/// The toolbar page draws them (`extensions` in its state, `ExtensionAction` in toolbarModel.ts);
/// this model follows the tab, runs a press (the action's popup or `onClicked`, anchored at its
/// button or at the Extensions button), shows an extension's menu on a right click, opens the
/// Extensions bubble (Chrome's `ExtensionsMenuView`, native), reorders a dragged pin, and reloads
/// crashed extensions from the warning button. Pinned actions past the pane's room (the page's
/// `visiblePinned`) are reached through the bubble.
@MainActor
final class ExtensionActions {
    /// Most pinned buttons shown before the rest overflow into the bubble.
    static let maxVisible = 6

    /// Accessibility identifiers (UI automation and the extension e2e suite).
    enum Identifier {
        static let menuButton = "browser.extensions.button"
        static func action(_ id: String) -> String { "browser.extension.action.\(id)" }
    }

    private(set) var host: (any BrowserExtensionActionHosting)?
    private weak var pageView: NSView?
    private var observation: ObservationLoop?
    private var prepareTask: Task<Void, Never>?
    private(set) var actions: [CEFExtensionAction] = []
    private var showsPuzzle = false
    /// The names of the crashed extensions of the tab's profile (the warning button), none: hidden.
    private var crashedNames: [String] = []
    /// The page's anchor for a control key (`action:<id>`, `extensions`); set by the chrome.
    var anchor: (String) -> NSView? = { _ in nil }
    /// Where the bubble opens while the Extensions button is not shown (More).
    var menuAnchor: (() -> NSView?)?
    /// What the page draws changed: the chrome pushes it.
    var onChange: (() -> Void)?
    /// Pinned buttons the page had room for (its `layout` report).
    var visibleLimit = ExtensionActions.maxVisible
    /// An extension's menu at its toolbar icon while it is open (`debug.extensions.menu`).
    private(set) weak var presentedMenu: NSMenu?
    private var pressedID: String?
    private var bubbleShown = false
    /// Icon data URLs by action id and the PNG they were made from (a re-render reuses them).
    private var iconURLs: [String: (png: Data, url: String)] = [:]
    /// Runs Extensions menu items (the App's registry actions). Nil drives the store directly.
    weak var menuHandler: (any ExtensionMenuHandling)?
    private var directHandler: ExtensionsMenu.DirectHandler?

    /// The Extensions bubble, made on first use (pointer, CLI, palette, More), never in a pane's key turn (#32909).
    private(set) var menuControllerIfMade: ExtensionsMenuController?
    var menuController: ExtensionsMenuController {
        if let menuControllerIfMade { return menuControllerIfMade }
        let controller = ExtensionsMenuController()
        controller.onShownChange = { [weak self] _, shown in
            self?.bubbleShown = shown
            self?.onChange?()
        }
        controller.toggleView = { [weak self] in self?.menuButtonAnchor }
        menuControllerIfMade = controller
        return controller
    }

    var isMenuShown: Bool { menuControllerIfMade?.isShown ?? false }
    /// Whether the bound tab shows the Extensions button.
    var isShowingExtensions: Bool { showsPuzzle }
    /// Pinned actions of the bound tab (before the room limit), capped.
    var pinnedCount: Int { min(Self.maxVisible, actions.filter(\.isPinned).count) }

    /// Binds to a tab; a tab without extensions empties the row's extension part.
    func bind(_ tab: any BrowserTab) {
        menuControllerIfMade?.close()
        observation?.cancel()
        observation = nil
        prepareTask?.cancel()
        host?.hideExtensionPopups()
        host?.extensionActionAnchor = nil
        host = (tab as? any BrowserExtensionActionHosting).flatMap { $0.showsExtensionToolbar ? $0 : nil }
        pageView = tab.contentView
        directHandler = nil
        guard let host else {
            update([], showsPuzzle: false, crashed: [])
            return
        }
        host.extensionActionAnchor = { [weak self] id in self?.anchorRect(for: id) }
        observation = ObservationLoop { [weak self] in
            guard let self, let host = self.host else { return }
            self.update(host.extensionActions, showsPuzzle: host.showsExtensionToolbar,
                        crashed: host.showsExtensionToolbar ? host.extensionStore.crashed.map(\.name) : [])
            if self.menuControllerIfMade != nil { self.schedulePrepare() }
        }
    }

    private func update(_ actions: [CEFExtensionAction], showsPuzzle: Bool, crashed: [String]) {
        guard actions != self.actions || showsPuzzle != self.showsPuzzle || crashed != crashedNames else { return }
        self.actions = actions
        self.showsPuzzle = showsPuzzle
        crashedNames = crashed
        onChange?()
    }

    /// Builds the bubble's rows on a later turn, off the click's path.
    private func schedulePrepare() {
        prepareTask?.cancel()
        prepareTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled, let host = self.host else { return }
            self.menuController.prepare(host: host)
        }
    }

    /// The pinned actions shown, in Chromium's order, capped.
    static func visible(_ actions: [CEFExtensionAction], limit: Int = maxVisible) -> [CEFExtensionAction] {
        Array(actions.filter(\.isPinned).prefix(max(0, min(maxVisible, limit))))
    }

    /// Ids of the actions shown as buttons, in order.
    var visibleIDs: [String] { Self.visible(actions, limit: visibleLimit).map(\.id) }
    /// Pinned actions the pane had no room for.
    var overflowIDs: [String] { actions.filter(\.isPinned).map(\.id).filter { !visibleIDs.contains($0) } }

    /// The row's `extensions` state: every pinned action (the page fits what it can), the
    /// Extensions button, the warning for crashed extensions, and what draws pressed.
    var wire: [String: Any] {
        var pinned: [[String: Any]] = []
        for action in Self.visible(actions) {
            var item: [String: Any] = ["id": action.id, "name": action.title.isEmpty ? action.name : action.title, "enabled": action.isEnabled,
                                       "label": action.name]
            // The badge is in the icon; VoiceOver reads it as the value (ExtensionActionButton did).
            if !action.badge.isEmpty { item["value"] = action.badge }
            if let icon = iconURL(for: action) { item["iconUrl"] = icon }
            pinned.append(item)
        }
        return [
            "shows": showsPuzzle,
            "pinned": pinned,
            "pressed": pressedID ?? NSNull(),
            "extensionsPressed": bubbleShown,
            "crashed": crashedNames.isEmpty ? NSNull() : ["label": Strings.extensionsCrashed(crashedNames)] as Any,
        ]
    }

    private func iconURL(for action: CEFExtensionAction) -> String? {
        guard let png = action.iconPNG else { return nil }
        if let cached = iconURLs[action.id], cached.png == png { return cached.url }
        let url = "data:image/png;base64," + png.base64EncodedString()
        iconURLs[action.id] = (png, url)
        return url
    }

    /// Where `id`'s popup anchors, in the tab's content view coordinates: its button, or the
    /// Extensions button when it is not shown (a popup opened from the bubble), else More.
    func anchorRect(for id: String) -> CGRect? {
        guard let page = pageView else { return nil }
        let source = anchor("action:\(id)") ?? anchor("extensions") ?? menuAnchor?()
        guard let source, source.window != nil, source.window === page.window else {
            let side = OmnibarMetrics.current.buttonSize
            return CGRect(x: page.bounds.maxX - side, y: 0, width: side, height: 1)
        }
        return source.convert(source.bounds, to: page)
    }

    /// Runs `id`'s action anchored where it is shown.
    func run(_ id: String) { host?.requestExtensionAction(id) }

    /// Closes any open action popup and the Extensions bubble (the pane resized, the tab changed or left).
    func hidePopups() {
        menuControllerIfMade?.close()
        host?.hideExtensionPopups()
    }

    /// The page is closing: the bubble's panel closes for good.
    func closeMenuPanel() { menuControllerIfMade?.closePanel() }

    private var handler: (any ExtensionMenuHandling)? {
        if let menuHandler { return menuHandler }
        guard let host else { return nil }
        if directHandler == nil {
            directHandler = ExtensionsMenu.DirectHandler(host: host) { [weak self] url in
                (self?.host as? any BrowserTab)?.load(url)
            }
        }
        return directHandler
    }

    /// The Extensions button: opens the bubble below it, or closes it when open.
    func showMenu() {
        guard let host, let handler, let anchor = menuButtonAnchor else { return }
        menuController.toggle(host: host, handler: handler, anchor: anchor)
    }

    /// Opens the Extensions bubble (the CLI, the palette, More); an open bubble stays open.
    func openMenu() {
        guard let host, let handler, !menuController.isShown, let anchor = menuButtonAnchor else { return }
        menuController.show(host: host, handler: handler, anchor: anchor)
    }

    /// The Extensions button, or More while it is not shown, or the page.
    private var menuButtonAnchor: NSView? {
        anchor("extensions") ?? menuAnchor?().flatMap { $0.window == nil ? nil : $0 } ?? pageView
    }

    /// One extension's context menu at its toolbar icon (right click), with Pin / Unpin as Chrome
    /// offers them there; at the Extensions button when the icon is not shown.
    func showItemMenu(_ id: String) {
        guard let host, let handler,
              let info = ExtensionsMenu().extensions(of: host).first(where: { $0.id == id }) else { return }
        let menu = ExtensionsMenu().itemMenu(for: info, supportsManagement: host.extensionStore.supportsManagement,
                                             handler: handler, fromToolbar: true)
        guard let view = anchor("action:\(id)") ?? menuButtonAnchor, view.window != nil else { return }
        let previous = presentedMenu
        presentedMenu = menu
        // Pressed while the menu is open, normal again when it closes (Chrome keeps the ink).
        setPressed(id)
        menu.popUp(positioning: nil, at: CmuxPopoverAnchor.menuPoint(for: menu, in: view, gap: 0), in: view)
        setPressed(nil)
        presentedMenu = previous
    }

    private func setPressed(_ id: String?) {
        pressedID = id
        onChange?()
    }

    /// Moves `id` to `index` among the pinned actions (drag, CLI, palette).
    @discardableResult
    func movePinned(_ id: String, to index: Int) -> Bool {
        host?.extensionStore.movePinned(id, to: index) ?? false
    }

    /// The warning button: reloads every crashed extension of the tab's profile.
    func reloadCrashed() {
        guard let store = host?.extensionStore else { return }
        for info in store.crashed { _ = store.reload(info.id) }
    }
}

/// Target for a menu item whose action is a closure.
final class MenuTrampoline: NSObject {
    var action: (() -> Void)?
    @objc func fire() { action?() }
}
