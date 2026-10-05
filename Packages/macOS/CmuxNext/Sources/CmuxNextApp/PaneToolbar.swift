import AppKit
import CmuxNextActions
import CmuxNextTabs
import Observation

/// The default trailing cluster of every pane's tab strip, used while
/// cmux.json sets no `ui.surfaceTabBar.buttons`. At most two buttons after
/// the strip's "+", picked by the kind of the pane's selected tab:
///
/// - terminal: split, more
/// - browser: split, more
/// - agent chat: more (its page header carries the chat's own tools)
///
/// Split runs Split Right on click and Split Down on Option-click; its menu
/// (right-click, press-and-hold) offers both. More opens the rest: files,
/// folder, windows, and the tab's duplicate and move. Every entry is a
/// registry action, so each keeps its shortcut and palette row.
enum PaneToolbar {
    enum Kind: Hashable, Sendable, CaseIterable {
        case terminal
        case browser
        case agent
    }

    static let splitID = "cmux.split"
    static let moreID = "cmux.more"

    static func buttonIDs(for kind: Kind) -> [String] {
        switch kind {
        case .terminal, .browser: [splitID, moreID]
        case .agent: [moreID]
        }
    }

    /// Action a button runs on click (none for More, whose click is its menu).
    static let actions: [String: ActionID] = [splitID: "splitRight"]
    /// Action a button runs on Option-click.
    static let alternates: [String: ActionID] = [splitID: "splitDown"]

    static func buttons(for kind: Kind, registry: ActionRegistry) -> [TabStripButton] {
        buttonIDs(for: kind).map { id in
            if id == splitID {
                let title = registry.title(for: "splitRight") ?? id
                let toolTip = registry.shortcutDisplay(for: "splitRight").map { Strings.tabBarButtonToolTip(title, shortcut: $0) } ?? title
                return TabStripButton(id: id, icon: .symbol("square.split.2x1"), toolTip: toolTip, accessibilityLabel: title, menu: .secondary)
            }
            return TabStripButton(id: id, icon: .symbol("ellipsis"), toolTip: Strings.tabBarMore, accessibilityLabel: Strings.tabBarMore, menu: .primary)
        }
    }

    static let splitEntries: [ContextMenuEntry] = [.action("splitRight"), .action("splitDown")]

    /// More's entries on the pane: the splits when the strip shows no split button.
    static func overflowPaneEntries(for kind: Kind) -> [ContextMenuEntry] {
        buttonIDs(for: kind).contains(splitID) ? [] : splitEntries
    }

    /// More's entries on the focused window: files, folder, a new window.
    static let overflowWindowEntries: [ContextMenuEntry] = [
        .action("toggleRightSidebar"), .action("openFolder"), .action("newWindow"),
    ]

    /// More's entries on the selected tab.
    static let overflowTabEntries: [ContextMenuEntry] = [.action("duplicateTab"), .action("tab.moveToNewWindow")]

    /// The menu of button `id` on pane `pane`, whose selected tab is `tab`; nil for any other button.
    static func menu(for id: String, kind: Kind, pane: String, tab: String?, registry: ActionRegistry) -> NSMenu? {
        let paneTarget = ActionTargetRef(kind: .pane, id: pane)
        switch id {
        case splitID:
            return registry.makeContextMenu(for: .pane, target: paneTarget, entries: splitEntries)
        case moreID:
            var sections = [
                registry.makeContextMenu(for: .pane, target: paneTarget, entries: overflowPaneEntries(for: kind)),
                registry.makeContextMenu(for: .pane, entries: overflowWindowEntries),
            ]
            if let tab {
                sections.append(registry.makeContextMenu(for: .tab, target: ActionTargetRef(kind: .tab, id: tab), entries: overflowTabEntries))
            }
            let menu = NSMenu()
            menu.autoenablesItems = true
            for section in sections where !section.items.isEmpty {
                if !menu.items.isEmpty { menu.addItem(.separator()) }
                for item in section.items {
                    section.removeItem(item)
                    menu.addItem(item)
                }
            }
            return menu
        default:
            return nil
        }
    }
}

extension PaneToolbar {
    /// The kind of `pane`'s selected tab, which picks its buttons.
    static func kind(of pane: PaneController) -> Kind {
        guard let id = pane.stripModel.selectedID?.rawValue else { return .terminal }
        if id.hasPrefix(LocalBrowserTab.prefix) { return .browser }
        if pane.services.agentTabs.isAgentTab(id) { return .agent }
        switch pane.tab(StripTabID(id))?.kind {
        case .browser?: return .browser
        case .conversation?: return .agent
        default: return .terminal
        }
    }

    /// Keeps `pane`'s strip buttons on cmux.json and on its selected tab's kind.
    static func observe(_ pane: PaneController, buttons: TabBarButtonsController) -> Task<Void, Never> {
        // task-owner: PaneController stores it (buttonsObservation) and cancels it on teardown
        Task { [weak pane] in
            for await list in Observations({ [weak pane] in pane.map { buttons.buttons(for: kind(of: $0)) } ?? [] }) {
                guard let pane else { return }
                if pane.stripModel.trailingButtons != list { pane.stripModel.trailingButtons = list }
            }
        }
    }

    /// The menu of button `id` on `pane`'s strip.
    static func menu(for id: String, in pane: PaneController) -> NSMenu? {
        menu(for: id, kind: kind(of: pane), pane: pane.paneKey, tab: pane.stripModel.selectedID?.rawValue, registry: pane.services.registry)
    }
}
