import AppKit
import CmuxNextDesign

/// Fills `BrowserChromeView.extensionSlot` like Chrome's toolbar: the pinned
/// extension actions of the bound tab in Chromium's order (icon plus native
/// badge), then the Extensions (puzzle) button, which is always there for a
/// tab with extensions. Pinned actions beyond `visibleLimit` (the pane's
/// room, `BrowserToolbarLayout`) are reached through that menu. Click runs
/// the action (popup or `onClicked`), anchored to its button or, when it is
/// not shown, to the Extensions button; right click shows the extension's
/// menu.
final class ExtensionActionToolbar {
    /// Most pinned buttons shown before the rest overflow into the menu.
    static let maxVisible = 6

    /// Accessibility identifiers (UI automation and the extension e2e suite).
    enum Identifier {
        static let menuButton = "browser.extensions.button"
        static func action(_ id: String) -> String { "browser.extension.action.\(id)" }
    }

    private let slot: NSStackView
    private(set) var host: (any BrowserExtensionActionHosting)?
    private weak var anchorView: NSView?
    private var observation: ObservationLoop?
    private var buttons: [String: ExtensionActionButton] = [:]
    private(set) lazy var puzzle: ChromeIconButton = {
        let button = ChromeIconButton(symbol: "puzzlepiece.extension", label: Strings.extensions,
                                      action: #selector(MenuTrampoline.fire), target: trampoline, toolbar: true)
        button.setAccessibilityIdentifier(Identifier.menuButton)
        return button
    }()
    private let trampoline = MenuTrampoline()
    let crashIndicator = ExtensionCrashIndicator()
    private var lastActions: [CEFExtensionAction] = []
    private var showsPuzzle = false
    private var afterMenu: [() -> Void] = []
    /// The Extensions menu or an extension's menu while it is open
    /// (`debug.extensions.menu`).
    private(set) weak var presentedMenu: NSMenu?

    /// Pinned buttons the pane has room for (`BrowserToolbarLayout`).
    var visibleLimit = ExtensionActionToolbar.maxVisible {
        didSet { if visibleLimit != oldValue { render(lastActions, showsPuzzle: showsPuzzle) } }
    }
    /// Pinned actions of the bound tab (before the room limit), capped.
    var pinnedCount: Int { min(Self.maxVisible, lastActions.filter(\.isPinned).count) }
    /// The pinned count or the puzzle's presence changed: the chrome
    /// recomputes its layout.
    var onPinnedCountChange: (() -> Void)?
    /// Whether the bound tab shows the Extensions button.
    var isShowingExtensions: Bool { showsPuzzle }
    /// Runs Extensions menu items (the App's registry actions). Nil drives
    /// the store directly (`ExtensionsMenu.DirectHandler`).
    weak var menuHandler: (any ExtensionMenuHandling)?
    private var directHandler: ExtensionsMenu.DirectHandler?

    init(slot: NSStackView) {
        self.slot = slot
        trampoline.action = { [weak self] in self?.showMenu() }
    }

    /// Binds the toolbar to a tab; a tab without extensions empties it.
    func bind(_ tab: any BrowserTab) {
        observation?.cancel()
        observation = nil
        host?.hideExtensionPopups()
        host?.extensionActionAnchor = nil
        host = (tab as? any BrowserExtensionActionHosting).flatMap { $0.showsExtensionToolbar ? $0 : nil }
        anchorView = tab.contentView
        directHandler = nil
        guard let host else {
            render([], showsPuzzle: false)
            crashIndicator.update(store: nil, in: slot, before: puzzle)
            return
        }
        host.extensionActionAnchor = { [weak self] id in self?.anchorRect(for: id) }
        observation = ObservationLoop { [weak self] in
            guard let self, let host = self.host else { return }
            self.render(host.extensionActions, showsPuzzle: host.showsExtensionToolbar)
            self.crashIndicator.update(store: host.showsExtensionToolbar ? host.extensionStore : nil,
                                       in: self.slot, before: self.puzzle)
        }
    }

    /// The visible actions: pinned, in Chromium's order, capped.
    static func visible(_ actions: [CEFExtensionAction], limit: Int = maxVisible) -> [CEFExtensionAction] {
        Array(actions.filter(\.isPinned).prefix(max(0, min(maxVisible, limit))))
    }

    /// Ids of the actions shown as buttons, in order.
    var visibleIDs: [String] { Self.visible(lastActions, limit: visibleLimit).map(\.id) }
    /// Pinned actions the pane had no room for.
    var overflowIDs: [String] { lastActions.filter(\.isPinned).map(\.id).filter { !visibleIDs.contains($0) } }

    func button(for id: String) -> NSView? { buttons[id] }

    private func render(_ actions: [CEFExtensionAction], showsPuzzle: Bool) {
        let pinnedBefore = pinnedCount
        let puzzleBefore = self.showsPuzzle
        lastActions = actions
        self.showsPuzzle = showsPuzzle
        if pinnedBefore != pinnedCount || puzzleBefore != showsPuzzle { onPinnedCountChange?() }
        let shown = Self.visible(actions, limit: visibleLimit)
        let ids = Set(shown.map(\.id))
        for (id, button) in buttons where !ids.contains(id) {
            slot.removeArrangedSubview(button)
            button.removeFromSuperview()
            buttons[id] = nil
        }
        for (index, action) in shown.enumerated() {
            let button = buttons[action.id] ?? makeButton(for: action.id)
            button.update(action)
            if let current = slot.arrangedSubviews.firstIndex(of: button) {
                guard current != index else { continue }
                slot.removeArrangedSubview(button)
            }
            slot.insertArrangedSubview(button, at: min(index, slot.arrangedSubviews.count))
        }
        let arranged = slot.arrangedSubviews.contains(puzzle)
        if showsPuzzle {
            if slot.arrangedSubviews.last !== puzzle {
                if arranged { slot.removeArrangedSubview(puzzle) }
                slot.addArrangedSubview(puzzle)
            }
        } else if arranged {
            slot.removeArrangedSubview(puzzle)
            puzzle.removeFromSuperview()
        }
    }

    /// Where `id`'s popup anchors, in the tab's content view coordinates:
    /// its button, or the Extensions button when it is not shown (as Chrome
    /// anchors a popup it pops out of the menu).
    func anchorRect(for id: String) -> CGRect? {
        guard let anchor = anchorView else { return nil }
        let source: NSView = buttons[id] ?? puzzle
        guard source.window != nil, source.window === anchor.window else {
            return CGRect(x: anchor.bounds.maxX - OmnibarStyle.buttonSize, y: 0, width: OmnibarStyle.buttonSize, height: 1)
        }
        // The alignment rect is the visible button (NSButton frames carry
        // bezel insets).
        let visible = source.alignmentRect(forFrame: source.frame)
        return source.superview.map { $0.convert(visible, to: anchor) } ?? visible
    }

    /// Runs `id`'s action anchored where it is shown.
    func run(_ id: String) {
        host?.requestExtensionAction(id)
    }

    /// Closes any open action popup (the pane resized, the tab changed).
    func hidePopups() { host?.hideExtensionPopups() }

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

    /// Shows the Extensions menu below the Extensions button and runs a
    /// row's deferred work once it closed.
    func showMenu() {
        guard let host, let handler, presentedMenu == nil else { return }
        host.extensionStore.refresh()
        let menu = ExtensionsMenu.make(
            for: host, handler: handler,
            afterClose: { [weak self] work in self?.afterMenu.append(work) },
            presentItemMenu: { [weak self] menu in self?.popUp(menu) }
        )
        popUp(menu)
        let work = afterMenu
        afterMenu.removeAll()
        for item in work { item() }
    }

    /// One extension's menu at its button (right click), or at the
    /// Extensions button.
    func showItemMenu(_ id: String) {
        guard let host, let handler,
              let info = ExtensionsMenu.extensions(of: host).first(where: { $0.id == id }) else { return }
        let menu = ExtensionsMenu.itemMenu(for: info, supportsManagement: host.extensionStore.supportsManagement,
                                           handler: handler)
        popUp(menu, at: buttons[id])
    }

    private func popUp(_ menu: NSMenu, at source: NSView? = nil) {
        let view: NSView = source ?? (puzzle.window == nil ? (anchorView ?? puzzle) : puzzle)
        // AppKit raises for a menu anchored in no window.
        guard view.window != nil else { return }
        let previous = presentedMenu
        presentedMenu = menu
        menu.popUp(positioning: nil, at: CGPoint(x: 0, y: view.isFlipped ? view.bounds.maxY + 4 : -4), in: view)
        presentedMenu = previous
    }

    private func makeButton(for id: String) -> ExtensionActionButton {
        let button = ExtensionActionButton(actionID: id)
        button.onRun = { [weak self] in self?.run(id) }
        button.onMenu = { [weak self] _ in self?.showItemMenu(id) }
        buttons[id] = button
        return button
    }
}

/// Target for a button whose action is a closure.
final class MenuTrampoline: NSObject {
    var action: (() -> Void)?
    @objc func fire() { action?() }
}
