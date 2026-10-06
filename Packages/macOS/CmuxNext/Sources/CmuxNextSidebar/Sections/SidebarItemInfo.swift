public import CmuxNextDesign
import Foundation

/// A small control on an item's trailing edge with its own action.
public nonisolated enum SidebarItemAccessory: Hashable, Sendable {
    /// An app update is available: a click installs it (on Settings).
    /// `title` is the control's tooltip and VoiceOver label, from the
    /// App ("Restart to Update" for a staged update).
    case update(title: String)
}

/// How a layout item draws. The sidebar knows built-ins; the App resolves
/// workspace, tab, room and other references (`SidebarModel.itemInfo`).
public nonisolated struct SidebarItemInfo: Hashable, Sendable {
    public var title: String
    /// SF Symbol name.
    public var symbol: String
    /// A swatch instead of the plain glyph tint.
    public var color: GroupColor?
    /// Count shown trailing (notifications, unread).
    public var badge: Int?
    /// The window shows this item (Home, a pinned workspace).
    public var isActive: Bool
    /// The reference no longer resolves (a closed workspace): drawn dimmed.
    public var isMissing: Bool
    /// Not drawn at all (a hidden app, D55); the item stays in the layout.
    public var isHidden: Bool
    /// The trailing control (`SidebarIntent.activateItemAccessory`).
    public var accessory: SidebarItemAccessory?
    /// The shorter caption a tile draws under its glyph; nil uses `title`.
    public var caption: String?

    public init(title: String, symbol: String, color: GroupColor? = nil, badge: Int? = nil, isActive: Bool = false, isMissing: Bool = false,
                isHidden: Bool = false, caption: String? = nil) {
        self.isHidden = isHidden
        self.caption = caption
        self.title = title
        self.symbol = symbol
        self.color = color
        self.badge = badge
        self.isActive = isActive
        self.isMissing = isMissing
    }
}

extension SidebarBuiltIn {
    /// SF Symbol of the built-in.
    public var symbol: String {
        switch self {
        case .home: "house"
        case .settings: "gearshape"
        case .account: "person.crop.circle"
        case .notifications: "bell"
        case .history: "clock.arrow.circlepath"
        case .bookmarks: "bookmark"
        case .appStore: "bag"
        case .newTerminal: "apple.terminal"
        case .newBrowser: "globe"
        case .newAgentChat: "bubble.left.and.text.bubble.right"
        case .customize: "paintbrush"
        case .newWorkspace: "plus"
        case .importSync: "square.and.arrow.down"
        }
    }

    /// Localized title.
    public var title: String {
        switch self {
        case .home: SectionStrings.home
        case .settings: SectionStrings.settings
        case .account: SectionStrings.account
        case .notifications: SectionStrings.notifications
        case .history: SectionStrings.history
        case .bookmarks: SectionStrings.bookmarks
        case .appStore: SectionStrings.appStore
        case .newTerminal: SectionStrings.newTerminal
        case .newBrowser: SectionStrings.newBrowser
        case .newAgentChat: SectionStrings.newAgentChat
        case .customize: SectionStrings.customize
        case .newWorkspace: SectionStrings.newWorkspace
        case .importSync: SectionStrings.importSync
        }
    }

    /// The short tile caption, where the title is too long for a tile.
    public var caption: String? {
        switch self {
        case .appStore: SectionStrings.appStoreCaption
        case .newWorkspace: SectionStrings.newWorkspaceCaption
        case .importSync: SectionStrings.importSyncCaption
        default: nil
        }
    }

    public var defaultInfo: SidebarItemInfo { SidebarItemInfo(title: title, symbol: symbol, caption: caption) }
}

extension SidebarItemInfo {
    /// What an item draws when the App supplied nothing: the built-in's own
    /// look, else its raw reference, dimmed.
    public static func fallback(for ref: LayoutItemRef) -> SidebarItemInfo {
        if let builtIn = ref.builtIn { return builtIn.defaultInfo }
        // First-party apps read as their former built-ins until the app
        // registry answers (R63/R64): Home stays "Home" at launch.
        if ref.kind == LayoutItemRef.appKind,
           let builtIn = SidebarLayoutDocument.firstPartyApps.first(where: { $0.value == ref.value })?.key {
            return builtIn.defaultInfo
        }
        let symbol = switch ref.kind {
        case LayoutItemRef.workspaceKind: "square.stack"
        case LayoutItemRef.tabKind: "terminal"
        case LayoutItemRef.roomKind: "circle.grid.2x2"
        case LayoutItemRef.savedGroupKind: "folder"
        case LayoutItemRef.urlKind: "globe"
        case LayoutItemRef.appKind: "app.dashed"
        default: "questionmark.square.dashed"
        }
        return SidebarItemInfo(title: ref.value, symbol: symbol, isMissing: true)
    }
}
