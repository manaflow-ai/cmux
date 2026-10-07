public import CmuxNextDesign
public import CmuxNextIcons
import Foundation

/// How a layout item draws. The sidebar knows built-ins; the App resolves
/// workspace, tab, room and other references (`SidebarModel.itemInfo`).
public nonisolated struct SidebarItemInfo: Hashable, Sendable {
    public var title: String
    /// SF Symbol name, drawn when `icon` is nil (a third-party app's symbol).
    public var symbol: String
    /// The cmux icon registry name the item draws.
    public var icon: IconName?
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
    /// The item's action shortcut as menus show it (`⌘,`), for the tooltip.
    public var shortcut: String?
    /// The shorter caption a tile draws under its glyph; nil uses `title`.
    public var caption: String?
    /// An agent's brand mark (`AgentBrandID`), drawn instead of `icon` (a Recents chat).
    public var brand: String?
    /// One emoji the item draws as its glyph (a workspace's emoji icon), before `brand` and `icon`.
    public var emoji: String?
    /// An unread dot instead of a count, in every look (What's New after an update).
    public var unreadDot = false
    /// The current profile's avatar (SIDEBAR-FOOTER-AND-SPACE-MENU
    /// amendment 2): an icon-only item with an avatar draws its initial in
    /// a circle with a small chevron, and a click opens the profile menu.
    public var avatar: SidebarAvatar?

    public init(title: String, symbol: String, icon: IconName? = nil, color: GroupColor? = nil, badge: Int? = nil, isActive: Bool = false,
                isMissing: Bool = false, isHidden: Bool = false, caption: String? = nil, shortcut: String? = nil, brand: String? = nil,
                emoji: String? = nil) {
        self.icon = icon
        self.emoji = emoji
        self.brand = brand
        self.shortcut = shortcut
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

/// A profile's avatar: the initial of its name in a tinted circle.
public nonisolated struct SidebarAvatar: Hashable, Sendable {
    /// The profile's name (tooltip and VoiceOver).
    public var name: String
    /// What the circle draws without a picture: the profile's initial, or up to
    /// two initials for the signed-in user.
    public var initial: String
    /// The profile's color; nil draws the neutral text color.
    public var color: GroupColor?
    /// The signed-in user's picture (PNG, JPEG), drawn round in place of the initial.
    public var imageData: Data?

    public init(name: String, color: GroupColor? = nil) {
        self.name = name
        self.initial = Self.initial(of: name)
        self.color = color
    }

    /// The signed-in cmux user: their picture, else their initials.
    public static func account(name: String, imageData: Data? = nil) -> SidebarAvatar {
        var avatar = SidebarAvatar(name: name)
        avatar.initial = initials(for: name)
        avatar.imageData = imageData
        return avatar
    }

    /// Up to two initials: the first letters of the first and last words ("Leo Li" is "LL"), of an
    /// email's local part, else "?".
    public static func initials(for name: String) -> String {
        let local = name.contains("@") ? String(name.prefix { $0 != "@" }) : name
        let words = local.split(whereSeparator: \.isWhitespace).compactMap(\.first)
        guard let first = words.first else { return "?" }
        let letters = words.count > 1 ? [first, words[words.count - 1]] : [first]
        return String(letters).uppercased()
    }

    /// The first letter or digit of `name`, uppercased; "?" when it has none.
    public static func initial(of name: String) -> String {
        guard let first = name.first(where: { $0.isLetter || $0.isNumber }) else { return "?" }
        return String(first).uppercased()
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
        case .searchChats: "magnifyingglass"
        }
    }

    /// The built-in's cmux icon.
    public var icon: IconName {
        switch self {
        case .home: .home
        case .settings: .settings
        case .account: .account
        case .notifications: .notification
        case .history: .history
        case .bookmarks: .bookmarkManager
        case .appStore: .store
        case .newTerminal: .terminalNew
        case .newBrowser: .browserNew
        case .newAgentChat: .agentChatNew
        case .customize: .theme
        case .searchChats: .search
        }
    }

    /// The built-in a first-party app replaced (Home, App Store), whose look it keeps.
    public static func firstParty(appID: String) -> SidebarBuiltIn? {
        SidebarLayoutDocument.firstPartyApps.first { $0.value == appID }?.key
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
        case .searchChats: SectionStrings.searchChats
        }
    }

    /// The short tile caption, where the title is too long for a tile.
    public var caption: String? {
        switch self {
        case .appStore: SectionStrings.appStoreCaption
        default: nil
        }
    }

    public var defaultInfo: SidebarItemInfo { SidebarItemInfo(title: title, symbol: symbol, icon: icon, caption: caption) }
}

extension SidebarItemInfo {
    /// An icon's tooltip: the title, and the shortcut when there is one
    /// ("Settings (⌘,)").
    public var toolTip: String {
        shortcut.map { SectionStrings.titleWithShortcut(title, $0) } ?? title
    }
}

extension SidebarItemInfo {
    /// What an item draws when the App supplied nothing: the built-in's own
    /// look, else its raw reference, dimmed.
    public static func fallback(for ref: LayoutItemRef) -> SidebarItemInfo {
        if let builtIn = ref.builtIn { return builtIn.defaultInfo }
        // First-party apps read as their former built-ins until the app
        // registry answers (R63/R64): Home stays "Home" at launch.
        if ref.kind == LayoutItemRef.appKind, let builtIn = SidebarBuiltIn.firstParty(appID: ref.value) {
            return builtIn.defaultInfo
        }
        let icon: IconName = switch ref.kind {
        case LayoutItemRef.workspaceKind: .workspace
        case LayoutItemRef.tabKind: .terminal
        case LayoutItemRef.roomKind: .space
        case LayoutItemRef.savedGroupKind: .folder
        case LayoutItemRef.urlKind: .browser
        case LayoutItemRef.appKind: .appGeneric
        default: .iconMissing
        }
        let symbol = IconCatalog.bundled.entry(for: icon)?.sf ?? "questionmark.square.dashed"
        return SidebarItemInfo(title: ref.value, symbol: symbol, icon: icon, isMissing: true)
    }

    /// `fallback(for:)` of the item's ref, titled with the label stored with
    /// the item (a closed workspace's last known name) when it has one.
    public static func fallback(for item: LayoutItem) -> SidebarItemInfo {
        var info = fallback(for: item.ref)
        if info.isMissing, let label = item.label { info.title = label }
        return info
    }
}
