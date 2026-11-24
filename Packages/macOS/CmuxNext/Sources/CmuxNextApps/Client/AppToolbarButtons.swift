public import AppKit
public import CmuxNextActions
public import CmuxNextDesign
import CmuxNextCompat

/// The apps' toolbar items (`contributes.toolbarItems`, titlebar-area.md 3) as the window's top-left band draws
/// them after Back and Forward: the daemon's list (`apps.toolbar.list`, ``AppsClient/toolbarItems``), one
/// ``TitlebarBandButton`` per item, the chrome's one size and look. A button runs its op; a menu button opens its
/// rows on press; past ``visibleItems`` the rest go in one overflow button's menu. A click runs through
/// `apps-run` as the person (``AppsClient/runToolbarItem(_:entry:)``). With no app contributing there are no
/// buttons, and the band is the built-in three.
@MainActor
public final class AppToolbarButtons: NSObject {
    /// App items shown before the overflow button (`TOOLBAR_VISIBLE_APP_ITEMS`, cmux-app-manifest).
    public static let visibleItems = 3

    public private(set) var items: [AppToolbarContribution] = []
    /// In band order, the overflow button last when there is one.
    public private(set) var buttons: [TitlebarBandButton] = []
    /// Runs a click on an item, or on one row of its menu.
    public var onRun: ((AppToolbarContribution, AppToolbarContribution.Entry?) -> Void)?
    /// An item's image when its icon is a package file (nil draws its symbol).
    public var image: ((AppToolbarContribution, CGFloat) -> NSImage?)?
    /// The view the buttons are subviews of (the toolbar band, which lays them out after Forward).
    private weak var host: NSView?
    /// The reveal the built-in buttons fade with (R83): the app buttons fade with them.
    private weak var reveal: HoverReveal?
    private var menuRegistry: ActionRegistry?
    private var observation: Task<Void, Never>?

    override public init() { super.init() }

    /// Draws the client's list in `host` and keeps drawing it: an install, a hide or a saved local manifest
    /// (`apps-changed`) redraws the buttons with no relaunch.
    public func follow(_ client: AppsClient, in host: NSView, reveal: HoverReveal?, registry: ActionRegistry? = nil) {
        self.host = host
        self.reveal = reveal
        menuRegistry = registry ?? ActionRegistry()
        onRun = { [weak client] item, entry in client?.runToolbarItem(item, entry: entry) }
        image = { [weak client] item, size in
            // The scene images' cache: a file inside the app's package only, decoded once.
            guard let image = AppBundleImageCache.shared.image(path: item.iconPath, in: client?.bundleDirectory(for: item.app))?.copy() as? NSImage
            else { return nil }
            image.size = NSSize(width: size, height: size)
            return image
        }
        observation?.cancel()
        // task-owner: this object (cancelled in deinit and on a second follow); event-driven (Observation)
        observation = Task { [weak self, weak client] in
            guard let client else { return }
            for await items in ObservationStream({ client.toolbarItems }) {
                guard let self else { return }
                show(items)
            }
        }
    }

    /// Draws `items` in place of the last list; an unchanged list changes nothing.
    public func show(_ items: [AppToolbarContribution]) {
        guard items != self.items else { return }
        let removed = buttons
        self.items = items
        let shown = items.count > Self.visibleItems ? Self.visibleItems - 1 : items.count
        var next = items.prefix(shown).enumerated().map { index, item in button(item, index: index) }
        if shown < items.count { next.append(overflowButton(Array(items.dropFirst(shown)))) }
        buttons = next
        for button in removed {
            reveal?.remove(button)
            button.removeFromSuperview()
        }
        guard let host else { return }
        for button in next {
            host.addSubview(button)
            reveal?.add(button)
        }
        host.needsLayout = true
        // The window root places the band from its slots' width.
        host.superview?.needsLayout = true
    }

    private func button(_ item: AppToolbarContribution, index: Int) -> TitlebarBandButton {
        let button = TitlebarBandButton(symbol: item.symbol ?? "puzzlepiece.extension")
        if item.symbol == nil, item.iconPath != nil, let image {
            button.customImage = { _, size in image(item, size) }
        }
        let title = item.title.resolved()
        button.tag = index
        button.setAccessibilityLabel(title)
        button.setAccessibilityIdentifier("cmux.titlebar.app.\(item.id)")
        button.themedToolTip = title
        switch item.kind {
        case .button:
            button.target = self
            button.action = #selector(runButton(_:))
        case .menu:
            button.pressMenu = { [weak self] in self?.entriesMenu(item) }
        }
        return button
    }

    /// One button whose menu lists the items past the visible ones: a button as a row, a menu button as a submenu.
    private func overflowButton(_ rest: [AppToolbarContribution]) -> TitlebarBandButton {
        let button = TitlebarBandButton(symbol: "ellipsis")
        let titles = rest.map { $0.title.resolved() }.joined(separator: ", ")
        button.setAccessibilityLabel(titles)
        button.setAccessibilityIdentifier("cmux.titlebar.app.overflow")
        button.themedToolTip = titles
        button.pressMenu = { [weak self] in
            guard let self else { return nil }
            let menu = NSMenu()
            for item in rest {
                switch item.kind {
                case .button:
                    menu.addItem(row(item.title.resolved(), AppToolbarClick(item: item, entry: nil), actionID: "button"))
                case .menu:
                    let parent = NSMenuItem(title: item.title.resolved(), action: nil, keyEquivalent: "")
                    parent.submenu = entriesMenu(item)
                    menu.addItem(parent)
                }
            }
            return menu
        }
        return button
    }

    private func entriesMenu(_ item: AppToolbarContribution) -> NSMenu {
        let menu = NSMenu()
        for (index, entry) in item.entries.enumerated() {
            menu.addItem(row(entry.title.resolved(), AppToolbarClick(item: item, entry: entry), actionID: "entry-\(index)"))
        }
        return menu
    }

    private func row(_ title: String, _ click: AppToolbarClick, actionID: String) -> NSMenuItem {
        let id = ActionID(rawValue: "apps.toolbar.\(click.item.id).\(actionID)")
        menuRegistry?.register(Action(id: id, title: title) { [weak self] in
            self?.onRun?(click.item, click.entry)
        })
        return menuRegistry?.makeMenuItem(for: id) ?? NSMenuItem(title: title, action: nil, keyEquivalent: "")
    }

    @objc private func runButton(_ sender: NSButton) {
        guard items.indices.contains(sender.tag) else { return }
        onRun?(items[sender.tag], nil)
    }

    // Not an isolated deinit: the task handle is Sendable and cancels from any thread.
    nonisolated deinit { observation?.cancel() }
}

extension AppsClient {
    /// The toolbar band's app buttons, drawn in `host` and kept current (``AppToolbarButtons/follow(_:in:reveal:)``).
    /// The band reads the answer at each layout; it keeps the buttons' owner alive for as long as it holds it.
    public func toolbarButtons(in host: NSView, reveal: HoverReveal?, registry: ActionRegistry? = nil) -> () -> [TitlebarBandButton] {
        let toolbar = AppToolbarButtons()
        toolbar.follow(self, in: host, reveal: reveal, registry: registry)
        return { toolbar.buttons }
    }
}

/// What one menu row runs.
private final class AppToolbarClick: NSObject {
    let item: AppToolbarContribution
    let entry: AppToolbarContribution.Entry?

    init(item: AppToolbarContribution, entry: AppToolbarContribution.Entry?) {
        self.item = item
        self.entry = entry
    }
}
