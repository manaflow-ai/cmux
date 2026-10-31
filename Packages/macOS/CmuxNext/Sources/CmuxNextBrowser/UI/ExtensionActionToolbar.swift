import AppKit
import CmuxNextDesign
import CmuxNextIcons

/// Fills `BrowserChromeView.extensionSlot` with the pinned extension
/// actions of the bound tab in Chromium's order (icon plus native
/// badge), then the Extensions (puzzle) button, which every Chromium tab
/// shows, as Chrome does (Lawrence 2026-10-18: "show extensions there by
/// default"; it replaced cx-d0d.81's puzzle-only-while-pinned rule). Pinned actions beyond `visibleLimit` (the pane's
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
        let button = ChromeIconButton(icon: .browserToolbarExtensions, label: Strings.extensions,
                                      action: #selector(MenuTrampoline.fire), target: trampoline, toolbar: true)
        button.setAccessibilityIdentifier(Identifier.menuButton)
        // Chrome opens the Extensions menu on the press, not the release.
        button.sendAction(on: [.leftMouseDown])
        return button
    }()
    /// The Extensions bubble (Chrome's `ExtensionsMenuView`).
    private(set) lazy var menuController: ExtensionsMenuController = {
        let controller = ExtensionsMenuController()
        controller.onShownChange = { view, shown in (view as? ChromeIconButton)?.isMenuOpen = shown }
        controller.toggleView = { [weak self] in
            guard let self else { return nil }
            return self.puzzle.window == nil ? self.menuAnchor?() : self.puzzle
        }
        return controller
    }()
    private let trampoline = MenuTrampoline()
    let crashIndicator = ExtensionCrashIndicator()
    private var lastActions: [CEFExtensionAction] = []
    private var showsPuzzle = false
    /// An extension's menu at its toolbar icon while it is open (`debug.extensions.menu`).
    private(set) weak var presentedMenu: NSMenu?
    /// Whether the Extensions bubble is open.
    var isMenuShown: Bool { menuController.isShown }

    /// Pinned buttons the pane has room for (`BrowserToolbarLayout`).
    var visibleLimit = ExtensionActionToolbar.maxVisible {
        didSet { if visibleLimit != oldValue, !isRendering { render(lastActions, showsPuzzle: showsPuzzle) } }
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
        menuController.close()
        observation?.cancel()
        observation = nil
        host?.hideExtensionPopups()
        host?.extensionActionAnchor = nil
        host = (tab as? any BrowserExtensionActionHosting).flatMap { $0.showsExtensionToolbar ? $0 : nil }
        anchorView = tab.contentView
        directHandler = nil
        // Another tab's icons appear at once.
        hasRendered = false
        for view in leaving.values { view.removeFromSuperview() }
        leaving = [:]
        guard let host else {
            render([], showsPuzzle: false)
            crashIndicator.update(store: nil, in: slot, before: puzzle)
            return
        }
        host.extensionActionAnchor = { [weak self] id in self?.anchorRect(for: id) }
        observation = ObservationLoop { [weak self] in
            guard let self, let host = self.host else { return }
            let actions = host.extensionActions
            self.render(actions, showsPuzzle: Self.showsPuzzle(host: host))
            self.crashIndicator.update(store: host.showsExtensionToolbar ? host.extensionStore : nil,
                                       in: self.slot, before: self.puzzle)
            self.schedulePrepare()
        }
    }

    private var prepareTask: Task<Void, Never>?

    /// Builds the Extensions bubble's rows on a later turn, off the click's path.
    private func schedulePrepare() {
        prepareTask?.cancel()
        prepareTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled, let host = self.host, self.slot.window != nil else { return }
            self.menuController.prepare(host: host)
        }
    }

    /// Whether a tab bound to `host` shows the Extensions button: every
    /// tab whose engine has the extension toolbar (Chromium), extensions
    /// installed or not, so Chrome's puzzle, its menu (Manage Extensions,
    /// Chrome Web Store) and the pinned icons are always one click away.
    static func showsPuzzle(host: (any BrowserExtensionActionHosting)?) -> Bool {
        host?.showsExtensionToolbar ?? false
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
        isRendering = true
        defer { isRendering = false }
        let pinsChanged = actions.filter(\.isPinned).map(\.id) != lastActions.filter(\.isPinned).map(\.id)
        // Chrome animates a pin or an unpin (about 0.2 s): the icon fades and the neighbours
        // slide. Not on a tab's first render, not under Reduce Motion.
        let animate = hasRendered && pinsChanged && Motion.overlays.animatesMovement && slot.window != nil
        hasRendered = true
        let update = { [self] () -> [() -> Void] in
            let pinnedBefore = pinnedCount
            let puzzleBefore = self.showsPuzzle
            lastActions = actions
            self.showsPuzzle = showsPuzzle
            if pinnedBefore != pinnedCount || puzzleBefore != showsPuzzle { onPinnedCountChange?() }
            return place(Self.visible(actions, limit: visibleLimit), showsPuzzle: showsPuzzle, animate: animate)
        }
        guard animate, let container = slot.superview else {
            _ = update()
            return
        }
        // Start from the frames on screen now.
        container.layoutSubtreeIfNeeded()
        // The toolbar's move token: about 0.2 s, like Chrome's toolbar icon animation.
        Motion.overlays.animateTimed(.move, in: container, { [self] in
            let before = Set(buttons.keys)
            pendingFinish += update()
            let after = Set(buttons.keys)
            lastPinAnimation = (after.subtracting(before).sorted(), before.subtracting(after).sorted())
            container.layoutSubtreeIfNeeded()
        }, completion: { [weak self] in self?.finishPinAnimation() })
    }

    /// Work left for the end of the running pin animation (removing faded-out buttons).
    private var pendingFinish: [() -> Void] = []

    private func finishPinAnimation() {
        let work = pendingFinish
        pendingFinish = []
        work.forEach { $0() }
    }
    /// Whether this tab rendered before (its first render does not animate).
    private var hasRendered = false
    /// A render is running: a `visibleLimit` change it causes does not render again.
    private var isRendering = false
    /// Buttons fading out after an unpin, kept over the toolbar until the fade ends.
    private(set) var leaving: [String: NSView] = [:]
    /// Ids of buttons fading in after a pin, until the fade ends.
    private(set) var arriving: Set<String> = []
    /// The last pin or unpin that animated: the ids that faded in and out (tests).
    private(set) var lastPinAnimation: (arrived: [String], left: [String])?

    /// Puts the `shown` buttons and the puzzle in the slot. Animating, a removed button fades
    /// where it was and a new one fades in; returns the work to run when the animation ends.
    private func place(_ shown: [CEFExtensionAction], showsPuzzle: Bool, animate: Bool) -> [() -> Void] {
        var finish: [() -> Void] = []
        let ids = Set(shown.map(\.id))
        for (id, button) in buttons where !ids.contains(id) {
            buttons[id] = nil
            guard animate, let container = slot.superview else {
                slot.removeArrangedSubview(button)
                button.removeFromSuperview()
                continue
            }
            // Out of the row at once, so the neighbours slide into its room while it fades
            // where it was.
            let frame = button.convert(button.bounds, to: container)
            slot.removeArrangedSubview(button)
            button.removeFromSuperview()
            button.translatesAutoresizingMaskIntoConstraints = true
            button.frame = frame
            container.addSubview(button)
            leaving[id] = button
            // motion: allow place(animate: true) runs only inside render()'s Motion.overlays.animateTimed group
            button.animator().alphaValue = 0
            finish.append { [weak self, weak button] in
                guard let button else { return }
                button.removeFromSuperview()
                if self?.leaving[id] === button { self?.leaving[id] = nil }
            }
        }
        for (index, action) in shown.enumerated() {
            let isNew = buttons[action.id] == nil
            if isNew, let old = leaving.removeValue(forKey: action.id) { old.removeFromSuperview() }
            let button = buttons[action.id] ?? makeButton(for: action.id)
            button.update(action)
            if isNew, animate {
                arriving.insert(action.id)
                button.alphaValue = 0
                // motion: allow place(animate: true) runs only inside render()'s Motion.overlays.animateTimed group
                button.animator().alphaValue = 1
                let id = action.id
                finish.append { [weak self] in self?.arriving.remove(id) }
            } else if isNew {
                button.alphaValue = 1
            }
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
        return finish
    }

    /// Where `id`'s popup anchors, in the tab's content view coordinates:
    /// its button, or the Extensions button when it is not shown (a popup
    /// opened from the menu).
    func anchorRect(for id: String) -> CGRect? {
        guard let anchor = anchorView else { return nil }
        // No button and no puzzle (nothing pinned): More, where the menu opened.
        let source: NSView = buttons[id] ?? (puzzle.window == nil ? menuAnchor?() : nil) ?? puzzle
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

    /// Closes any open action popup and the Extensions bubble (the pane resized, the tab
    /// changed or left the window).
    func hidePopups() {
        menuController.close()
        host?.hideExtensionPopups()
    }

    /// The page is closing: the Extensions bubble's panel closes for good.
    func closeMenuPanel() {
        menuController.closePanel()
    }

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

    /// The Extensions button: opens the Extensions bubble below it, or closes it when open.
    func showMenu() {
        guard let host, let handler else { return }
        menuController.toggle(host: host, handler: handler, anchor: menuButtonAnchor)
    }

    /// Opens the Extensions bubble (the CLI, the palette, More); an open bubble stays open.
    func openMenu() {
        guard let host, let handler, !menuController.isShown else { return }
        menuController.show(host: host, handler: handler, anchor: menuButtonAnchor)
    }

    /// The Extensions button, or More while the button is not shown.
    private var menuButtonAnchor: NSView {
        let fallback = menuAnchor?().flatMap { $0.window == nil ? nil : $0 } ?? anchorView ?? puzzle
        return puzzle.window == nil ? fallback : puzzle
    }

    /// One extension's context menu at its toolbar icon (right click), with Pin / Unpin as
    /// Chrome offers them there; at the Extensions button when the icon is not shown.
    func showItemMenu(_ id: String) {
        guard let host, let handler,
              let info = ExtensionsMenu().extensions(of: host).first(where: { $0.id == id }) else { return }
        let menu = ExtensionsMenu().itemMenu(for: info, supportsManagement: host.extensionStore.supportsManagement,
                                             handler: handler, fromToolbar: true)
        popUp(menu, at: buttons[id])
    }

    /// Where the Extensions menu opens while the puzzle is hidden (More).
    var menuAnchor: (() -> NSView?)?

    private func popUp(_ menu: NSMenu, at source: NSView? = nil) {
        let fallback = menuAnchor?().flatMap { $0.window == nil ? nil : $0 } ?? anchorView ?? puzzle
        let view: NSView = source ?? (puzzle.window == nil ? fallback : puzzle)
        // AppKit raises for a menu anchored in no window.
        guard view.window != nil else { return }
        let previous = presentedMenu
        presentedMenu = menu
        // Pressed while the menu is open, normal again when it closes (Chrome keeps the ink).
        (view as? ExtensionActionButton)?.isMenuOpen = true
        (view as? ChromeIconButton)?.isMenuOpen = true
        menu.popUp(positioning: nil, at: CmuxPopoverAnchor.menuPoint(for: menu, in: view, gap: 0), in: view)
        (view as? ExtensionActionButton)?.isMenuOpen = false
        (view as? ChromeIconButton)?.isMenuOpen = false
        presentedMenu = previous
    }

    private func makeButton(for id: String) -> ExtensionActionButton {
        let button = ExtensionActionButton(actionID: id)
        button.onRun = { [weak self] in self?.run(id) }
        button.onMenu = { [weak self] _ in self?.showItemMenu(id) }
        button.canDrag = { [weak self] in self?.host?.extensionStore.supportsPinnedOrder == true }
        button.onDragMoved = { [weak self] dx in self?.dragMoved(id, dx: dx) }
        button.onDragEnded = { [weak self] dx in self?.dragEnded(id, dx: dx) }
        buttons[id] = button
        return button
    }

    // MARK: Reordering pinned buttons

    /// The pinned index a drag of `id` by `dx` points at.
    func dragTarget(_ id: String, dx: CGFloat) -> Int? {
        let shown = visibleIDs
        guard let from = shown.firstIndex(of: id) else { return nil }
        let step = OmnibarStyle.buttonSize + OmnibarStyle.buttonSpacing
        return min(max(from + Int((dx / step).rounded()), 0), shown.count - 1)
    }

    private func dragMoved(_ id: String, dx: CGFloat) {
        guard let target = dragTarget(id, dx: dx), let from = visibleIDs.firstIndex(of: id) else { return }
        let step = OmnibarStyle.buttonSize + OmnibarStyle.buttonSpacing
        for (index, other) in visibleIDs.enumerated() {
            var shift: CGFloat = 0
            if other == id {
                shift = dx
            } else if from < target, index > from, index <= target {
                shift = -step
            } else if target < from, index >= target, index < from {
                shift = step
            }
            buttons[other]?.layer?.setAffineTransform(CGAffineTransform(translationX: shift, y: 0))
        }
    }

    private func dragEnded(_ id: String, dx: CGFloat) {
        let target = dragTarget(id, dx: dx)
        for button in buttons.values { button.layer?.setAffineTransform(.identity) }
        guard let target, target != visibleIDs.firstIndex(of: id) else { return }
        movePinned(id, to: target)
    }

    /// Moves `id` to `index` among the pinned actions (drag, CLI, palette).
    @discardableResult
    func movePinned(_ id: String, to index: Int) -> Bool {
        host?.extensionStore.movePinned(id, to: index) ?? false
    }
}

/// Target for a button whose action is a closure.
final class MenuTrampoline: NSObject {
    var action: (() -> Void)?
    @objc func fire() { action?() }
}
