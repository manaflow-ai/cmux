public import CmuxNextDesign

extension SidebarItemInfo {
    /// A workspace row's title and the glyph it stands for, as a band item (a top row or a tile) draws it.
    ///
    /// The user's symbol (tinted) or emoji; else the row's favicon (its stored image or its page's), or the globe of a
    /// site with no favicon yet (``WorkspaceIcon/pagePlaceholder``); else none, text only, with no kind glyph or agent
    /// brand (WORKSPACE-ROWS-NO-DEFAULT-ICON). A favicon or globe item and a color dot take `color`.
    /// - Parameters:
    ///   - row: The workspace's sidebar row (`SidebarMapping.row`, the one row rule).
    ///   - color: The workspace's color as the sidebar shows it; nil when none is set or colors are off.
    public init(workspaceRow row: SidebarWorkspace, color: GroupColor?) {
        switch row.icon {
        case .symbol(let name, let tint)?: self.init(title: row.title, symbol: name, color: tint)
        case .emoji(let text, let chip)?: self.init(title: row.title, symbol: "face.smiling", color: chip, emoji: text)
        case .favicon(let image)?:
            self.init(title: row.title, symbol: WorkspaceIcon.pagePlaceholderSymbol, color: color)
            favicon = image
        // The browser tab's own globe until the favicon loads, as the tab draws it.
        case .pagePlaceholder?: self.init(title: row.title, symbol: WorkspaceIcon.pagePlaceholderSymbol, icon: WorkspaceIcon.pagePlaceholderIcon, color: color)
        case .page(let name)?: self.init(title: row.title, symbol: WorkspaceIcon.pagePlaceholderSymbol, icon: name, color: color)
        case .swatch?, nil:
            // A color shows as the list row's dot before the title (SidebarItemRowView); no color, the title alone.
            self.init(title: row.title, symbol: "textformat", color: row.icon == nil ? nil : color)
            textOnly = true
        }
        iconFromShownTab = row.iconFromShownTab
    }

    /// This item as a pinned row draws it: a shown tab's icon gives way to the pin, so the row reads as a workspace
    /// with no icon of its own (text only); an icon or color the user chose keeps the pin's place (#38061).
    public func droppingShownTabIcon() -> SidebarItemInfo {
        guard iconFromShownTab else { return self }
        var info = self
        (info.symbol, info.icon, info.favicon, info.emoji, info.color) = ("textformat", nil, nil, nil, nil)
        info.textOnly = true
        return info
    }
}
