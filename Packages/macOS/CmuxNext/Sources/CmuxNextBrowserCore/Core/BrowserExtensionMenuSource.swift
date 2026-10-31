package import Foundation

/// One enabled extension that may have added rows to a page's context
/// menu: what ``BrowserExtensionMenuIcons`` needs to tell which top-level
/// row is its own and which icon that row shows.
public nonisolated struct BrowserExtensionMenuSource: Hashable, Sendable {
    public var id: String
    /// The extension's (localized) name: the title Chromium gives the
    /// submenu that groups an extension's rows.
    public var name: String
    /// The manifest's `short_name`, localized; nil when it has none.
    public var shortName: String?
    /// The manifest icon for 1x screens: the smallest of at least 16 px.
    public var icon1x: String?
    /// The manifest icon for Retina screens: the smallest of at least 32 px.
    public var icon2x: String?
    /// The manifest asks for `contextMenus` or `menus`, or could not be read
    /// (then it may have rows too). An extension without either cannot add
    /// page menu rows.
    public var mayAddMenuItems: Bool

    public init(id: String, name: String, shortName: String? = nil, icon1x: String? = nil, icon2x: String? = nil,
                mayAddMenuItems: Bool = true) {
        self.id = id
        self.name = name
        self.shortName = shortName
        self.icon1x = icon1x
        self.icon2x = icon2x
        self.mayAddMenuItems = mayAddMenuItems
    }

    /// The icon its menu row shows; ``BrowserContextMenuIcon/defaultExtension``
    /// when the manifest lists none (Chrome's default extension icon).
    public var menuIcon: BrowserContextMenuIcon {
        icon1x == nil && icon2x == nil ? .defaultExtension : .image(oneX: icon1x, twoX: icon2x)
    }
}
