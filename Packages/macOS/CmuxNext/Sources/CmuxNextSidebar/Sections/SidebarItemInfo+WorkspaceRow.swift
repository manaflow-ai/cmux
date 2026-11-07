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
        case .pagePlaceholder?: self.init(title: row.title, symbol: WorkspaceIcon.pagePlaceholderSymbol, color: color)
        case .swatch?, nil:
            // A color shows as the list row's dot before the title (SidebarItemRowView); no color, the title alone.
            self.init(title: row.title, symbol: "textformat", color: row.icon == nil ? nil : color)
            textOnly = true
        }
    }
}
