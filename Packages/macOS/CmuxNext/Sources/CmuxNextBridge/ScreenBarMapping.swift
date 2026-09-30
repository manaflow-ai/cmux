public import CmuxNextDaemon
import CmuxNextDesign
public import CmuxNextTabs

/// Maps a workspace's screens into the bottom screen tab bar. Screens are a
/// tab strip of their own: one item per screen, in daemon order, with the
/// screen's name, color, icon, pin, and group.
public enum ScreenBarMapping {
    public struct Snapshot: Equatable, Sendable {
        public var items: [TabItem]
        public var groups: [TabGroupItem]
        /// The bar exists only while the workspace has two or more screens
        /// (REWRITE.md goal 5: no screen UI until the user opts in).
        public var isVisible: Bool
    }

    /// `untitled(n)` names the n-th (1-based) screen that has no name;
    /// `emojiIcon` renders an emoji icon (the App draws it to an image).
    @MainActor
    public static func snapshot(_ workspace: WorkspaceModel, untitled: (Int) -> String,
                                emojiIcon: (String) -> TabIcon) -> Snapshot {
        let items = workspace.screens.enumerated().map { index, screen in
            item(screen, number: index + 1, untitled: untitled, emojiIcon: emojiIcon)
        }
        let groups = workspace.screenGroups.map { group in
            TabGroupItem(id: TabGroupID(group.id.rawValue), name: group.name,
                         colorToken: group.color.flatMap(GroupColor.init(rawValue:)) ?? .grey,
                         isCollapsed: group.collapsed, isSaved: group.savedID != nil)
        }
        return Snapshot(items: items, groups: groups, isVisible: workspace.screens.count > 1)
    }

    @MainActor
    static func item(_ screen: ScreenModel, number: Int, untitled: (Int) -> String,
                     emojiIcon: (String) -> TabIcon) -> TabItem {
        let name = screen.name?.trimmingCharacters(in: .whitespaces) ?? ""
        let tabs = screen.panes.flatMap(\.tabs)
        let pane = screen.defaultPane.flatMap(screen.pane) ?? screen.panes.first
        let focused = pane.flatMap { $0.tabs.indices.contains($0.defaultTabIndex) ? $0.tabs[$0.defaultTabIndex] : $0.tabs.first }
        return TabItem(
            id: TabID(screen.id),
            title: name.isEmpty ? untitled(number) : name,
            subtitle: focused.flatMap { $0.cwd.map(SidebarMapping.abbreviate) ?? $0.url },
            icon: icon(screen.icon, emoji: emojiIcon),
            isPinned: screen.pinned,
            isUnread: tabs.contains(where: \.hasUnread),
            isBusy: false,
            status: tabs.contains { $0.agent?.state == .blocked } ? .needsInput : .none,
            groupID: screen.group.map { TabGroupID($0.rawValue) },
            tint: screen.color.flatMap(GroupColor.init(rawValue:))
        )
    }

    static func icon(_ value: String?, emoji: (String) -> TabIcon) -> TabIcon {
        guard let value, !value.isEmpty else { return .none }
        return isSymbolName(value) ? .symbol(value) : emoji(value)
    }

    /// SF Symbol names are ASCII words joined by dots (`server.rack`,
    /// `1.circle`); anything else is treated as an emoji.
    public static func isSymbolName(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (scalar.properties.isAlphabetic || ("0"..."9").contains(scalar) || scalar == ".")
        }
    }
}
