public import AppKit
public import CmuxNextActions
import CmuxNextCompat
public import CmuxNextDesign
import CmuxNextSidebar
import Foundation
import Observation

/// The Chief's tools in the docked Home's tab row (Leo 2026-10-20: the Chief's pane gets a top-right
/// area like a workspace's, with its status, its subagents and its actions;
/// `HomeDockSwitchView.rowTools`): the Chief's status mark (``ChiefSidebar/status``, what its sidebar
/// item shows), Subagents (each row opens like its sidebar row) and Chief Actions. Every slot keeps
/// its width, so a status change or a first subagent never moves the tabs.
public final class ChiefPaneTools: NSView {
    public let indicator = StatusIndicatorView()
    public let subagentsButton = TitlebarBandButton(symbol: "person.2")
    /// The app's one more button (⋮, OverflowButton); its menu opens on press.
    public let actionsButton = OverflowButton(label: ChiefToolStrings.actions)
    /// What Chief Actions lists, in this order (each runs on the shown Chief, as from the palette).
    public static let actions: [ActionID] = ["home.stopChief", "home.toggleChiefSettings", "chief.openMemoryInspector",
                                             "chief.openUsage", "home.newChief"]
    private let chief: ChiefSidebar
    private weak var registry: ActionRegistry?
    private var watch: Task<Void, Never>?
    private var shownInRow = ChromeTunables.tabRowTools.value

    public init(chief: ChiefSidebar = .shared, registry: ActionRegistry) {
        self.chief = chief
        self.registry = registry
        super.init(frame: .zero)
        setAccessibilityIdentifier("cmux.chief.paneTools")
        indicator.tracksWindowOcclusion = true
        subagentsButton.target = self
        subagentsButton.action = #selector(openMenu(_:))
        subagentsButton.longPressOpensMenu = false
        subagentsButton.themedToolTip = ChiefToolStrings.subagents
        subagentsButton.setAccessibilityLabel(ChiefToolStrings.subagents)
        subagentsButton.setAccessibilityIdentifier("cmux.chief.paneTools.subagents")
        actionsButton.setAccessibilityIdentifier("cmux.chief.paneTools.actions")
        [subagentsButton, actionsButton, indicator].forEach(addSubview)
        subagentsButton.pressMenu = { [weak self] in self?.subagentsMenu() }
        actionsButton.pressMenu = { [weak self] in self?.actionsMenu() }
        // task-owner: this view (cancelled in deinit); event-driven (Observation).
        watch = Task { [weak self, chief] in
            for await (status, subagents, inRow) in ObservationStream({ (chief.status, chief.allSubagents().count, ChromeTunables.tabRowTools.value) }) {
                guard let self else { return }
                show(status, subagents: subagents)
                // The setting decides whether the dock reports these tools (HomeDockSwitchView+TabRow).
                if inRow != shownInRow { shownInRow = inRow; superview?.needsLayout = true }
            }
        }
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // cx-t7hu: not an isolated deinit; its runtime hop traps when released inside an action's task-local scope.
    nonisolated deinit {
        guard Thread.isMainThread else { return } // main-proof: returns off the main thread
        MainActor.assumeIsolated { watch?.cancel() }
    }

    override public var isFlipped: Bool { true }
    override public var mouseDownCanMoveWindow: Bool { false }

    private static var slot: CGFloat { TitlebarBandButton.side }

    override public var intrinsicContentSize: NSSize {
        NSSize(width: Self.slot * 3 + Metrics.space1 * 2, height: Self.slot)
    }

    override public func layout() {
        super.layout()
        let side = Self.slot, y = max(0, (bounds.height - side) / 2)
        for (index, view) in [indicator, subagentsButton, actionsButton].enumerated() {
            let x = CGFloat(index) * (side + Metrics.space1)
            let mark = view === indicator ? Metrics.smallIconSize : side
            view.frame = NSRect(x: x + (side - mark) / 2, y: y + (side - mark) / 2, width: mark, height: mark)
        }
    }

    /// The Chief's status on the mark (hidden while idle, its slot kept) and whether it has subagents.
    func show(_ status: ChiefSidebar.Status, subagents: Int) {
        if indicator.state != status.activity { indicator.configure(status.activity) }
        subagentsButton.isEnabled = subagents > 0
    }

    /// A keyboard or VoiceOver press opens the button's menu (a click opens it on press).
    @objc private func openMenu(_ sender: TitlebarBandButton) {
        guard let menu = sender.pressMenu?(), !menu.items.isEmpty else { return }
        sender.presentMenu(menu, sender)
    }

    /// Every subagent, with its status; a row runs Open Chief Subagent on its sidebar row's item,
    /// as a click on that row does.
    func subagentsMenu() -> NSMenu {
        let menu = NSMenu()
        guard let registry else { return menu }
        for row in chief.allSubagents() {
            let target = ActionTargetRef(kind: .sidebarItem, id: row.item.id.rawValue)
            let built = registry.makeContextMenu(for: .sidebarItem, target: target, entries: [.action(ChiefSidebar.openSubagentAction)])
            guard let item = built.items.first else { continue }
            built.removeItem(item)
            // The subagent's own row: its title and status, no action icon or key.
            (item.title, item.toolTip, item.image) = (row.info.title, row.info.activity.shortLabel, nil)
            (item.keyEquivalent, item.keyEquivalentModifierMask) = ("", [])
            menu.addItem(item)
        }
        return menu
    }

    /// Chief Actions, as the catalog titles and keys them.
    func actionsMenu() -> NSMenu? {
        guard let registry else { return nil }
        let menu = NSMenu()
        for id in Self.actions { if let item = registry.makeMenuItem(for: id) { menu.addItem(item) } }
        return menu
    }
}

/// Strings of the Chief's pane tools (Resources/Localizable.xcstrings).
enum ChiefToolStrings {
    static var subagents: String { String(localized: "chief.tools.subagents", defaultValue: "Subagents", bundle: .module) }
    static var actions: String { String(localized: "chief.tools.actions", defaultValue: "Chief Actions", bundle: .module) }
}
