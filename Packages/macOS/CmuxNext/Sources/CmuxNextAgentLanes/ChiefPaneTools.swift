public import AppKit
public import CmuxNextActions
import CmuxNextCompat
public import CmuxNextDesign
import CmuxNextSidebar
import Foundation
import Observation

/// The Chief's tools in the docked Home's tab row (Leo 2026-10-20: the Chief's pane gets a top-right
/// area like a workspace's; `HomeDockSwitchView.rowTools`): only the Chief's status mark
/// (``ChiefSidebar/status``, what its sidebar item shows; hidden while idle, its slot kept, so a
/// status change never moves the tabs). Chief Actions and Subagents are rows at the top of the
/// pane's one more menu (⋮, ``PaneMoreMenuContributing``), not buttons of their own (Lawrence
/// 2026-10-22: "fix it so it's simple, like tf are these buttons for").
public final class ChiefPaneTools: NSView, PaneMoreMenuContributing {
    public let indicator = StatusIndicatorView()
    /// What Chief Actions lists, in this order (each runs on the shown Chief, as from the palette).
    public static let actions: [ActionID] = ["home.stopChief", "home.stopAllAgents", "home.toggleChiefSettings",
                                             "chief.openMemoryInspector", "chief.openUsage", "home.newChief"]
    private let chief: ChiefSidebar
    private weak var registry: ActionRegistry?
    private var watch: Task<Void, Never>?
    private var shownInRow = ChromeTunables.tabRowTools.value
    /// The Chief has a subagent now (the Subagents row is enabled).
    public private(set) var hasSubagents = false

    public init(chief: ChiefSidebar = .shared, registry: ActionRegistry) {
        self.chief = chief
        self.registry = registry
        super.init(frame: .zero)
        setAccessibilityIdentifier("cmux.chief.paneTools")
        indicator.tracksWindowOcclusion = true
        addSubview(indicator)
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

    override public var intrinsicContentSize: NSSize { NSSize(width: Self.slot, height: Self.slot) }

    override public func layout() {
        super.layout()
        let side = Self.slot, mark = Metrics.smallIconSize, y = max(0, (bounds.height - side) / 2)
        indicator.frame = NSRect(x: (side - mark) / 2, y: y + (side - mark) / 2, width: mark, height: mark)
    }

    /// The Chief's status on the mark (hidden while idle, its slot kept) and whether it has subagents.
    func show(_ status: ChiefSidebar.Status, subagents: Int) {
        if indicator.state != status.activity { indicator.configure(status.activity) }
        hasSubagents = subagents > 0
    }

    /// The pane's more menu's first rows: Chief Actions, then Subagents (a submenu of every
    /// subagent, disabled with none).
    public func paneMoreMenuItems() -> [NSMenuItem] {
        var items = actionsMenu()?.items ?? []
        items.forEach { $0.menu?.removeItem($0) }
        let subagents = NSMenuItem(title: ChiefToolStrings.subagents, action: nil, keyEquivalent: "")
        subagents.identifier = NSUserInterfaceItemIdentifier("cmux.chief.paneTools.subagents")
        subagents.image = NSImage(systemSymbolName: "person.2", accessibilityDescription: nil)
        let menu = subagentsMenu()
        subagents.submenu = menu
        subagents.isEnabled = !menu.items.isEmpty
        if !items.isEmpty { items.append(.separator()) }
        items.append(subagents)
        return items
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

/// Strings of the Chief's pane tools and Open Chief Subagent (Resources/Localizable.xcstrings).
enum ChiefToolStrings {
    static var subagents: String { String(localized: "chief.tools.subagents", defaultValue: "Subagents", bundle: .module) }
    static var actions: String { String(localized: "chief.tools.actions", defaultValue: "Chief Actions", bundle: .module) }
    /// A Chief subagent's row or menu item before its chat has a title.
    nonisolated static var subagent: String { String(localized: "chief.subagent.untitled", defaultValue: "Subagent", bundle: .module) }
    /// Open Chief Subagent's refusal when its run names no subagent row.
    static var noSubagent: String {
        String(localized: "chief.openSubagent.noSubagent", defaultValue: "Choose a subagent from the Subagents menu or the sidebar.", bundle: .module)
    }
}
