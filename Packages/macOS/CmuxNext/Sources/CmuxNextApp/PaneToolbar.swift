import AppKit
import CmuxNextActions
import CmuxNextDaemon
import CmuxNextSettings
import CmuxNextTabs
import Observation

/// The trailing buttons of each pane's tab strip: the cmux.json list
/// (`ui.surfaceTabBar.buttons`) or, while it sets none, the default for the
/// kind of the pane's selected tab:
///
/// - terminal, browser: Split Right, Split Down
/// - agent chat: none (its page header carries the chat's own tools)
///
/// Every button stays visible up to `maxVisibleButtons`. Only a longer list
/// is compacted: its first buttons stay and a "..." button lists the rest,
/// each row running the same registry action as its button.
enum PaneToolbar {
    enum Kind: Hashable, Sendable, CaseIterable {
        case terminal
        case browser
        case agent
    }

    static let moreID = "cmux.more"
    /// The most buttons a strip shows; a longer list shows one fewer plus "...".
    static let maxVisibleButtons = 4

    private static let splitButtonIDs: Set<String> = ["cmux.splitRight", "cmux.splitDown"]

    static func defaultSpecs(for kind: Kind) -> [TabBarButtonSpec] {
        switch kind {
        case .terminal, .browser: SurfaceTabBarConfig.builtInButtons.filter { splitButtonIDs.contains($0.id) }
        case .agent: []
        }
    }

    /// What a strip shows for `buttons`: all of them, or past
    /// `maxVisibleButtons` the first ones and "...".
    static func visible(_ buttons: [TabStripButton]) -> [TabStripButton] {
        guard buttons.count > maxVisibleButtons else { return buttons }
        return Array(buttons.prefix(maxVisibleButtons - 1)) + [moreButton]
    }

    /// The buttons "..." lists for `buttons` (none while all are visible).
    static func overflow(_ buttons: [TabStripButton]) -> [TabStripButton] {
        guard buttons.count > maxVisibleButtons else { return [] }
        return Array(buttons.dropFirst(maxVisibleButtons - 1))
    }

    static var moreButton: TabStripButton {
        TabStripButton(id: moreID, icon: .symbol("ellipsis"), toolTip: Strings.tabBarMore,
                       accessibilityLabel: Strings.tabBarMore, opensMenu: true)
    }
}

extension PaneToolbar {
    /// The kind of `pane`'s selected tab, which picks its default buttons.
    static func kind(of pane: PaneController) -> Kind {
        guard let id = pane.stripModel.selectedID?.rawValue else { return .terminal }
        if id.hasPrefix(LocalBrowserTab.prefix) { return .browser }
        if pane.services.agentTabs.isAgentTab(id) { return .agent }
        switch pane.tab(TabID(id))?.kind {
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

    /// The menu of button `id` on `pane`'s strip: "..." lists the buttons
    /// that did not fit; no other button has one.
    static func menu(for id: String, in pane: PaneController) -> NSMenu? {
        guard id == moreID else { return nil }
        return pane.services.tabBarButtons.overflowMenu(for: kind(of: pane), paneKey: pane.paneKey)
    }
}
