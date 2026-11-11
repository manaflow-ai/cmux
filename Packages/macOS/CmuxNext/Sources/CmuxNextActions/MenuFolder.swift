/// A titled submenu that collects the less used rows of a right-click menu
/// ("Move ▸", "Copy ▸"). A placement names its folder; the menu shows the
/// folder as one row after its group's rows, in declaration order. A folder with one row in a
/// menu shows that row inline instead.
public nonisolated enum MenuFolder: String, CaseIterable, Sendable, Hashable {
    case new
    case split
    case agent
    case openIn
    case appearance
    case options
    case group
    case move
    /// Sort orders (the sidebar's Sort ▸).
    case sort
    case layout
    case connection
    case copy
    case tools
    case close
    /// Bulk archive rows (Archive Others, Below, Above), after Close's rows.
    case archive
    /// Every row a crowded menu keeps off its top level (`ContextMenuEssentials`).
    case more

    /// Where the folder row sits in its menu (the Rust catalog's `MENU_FOLDERS`).
    public var group: MenuGroup { RustActionCatalog.shared.folders[self]?.group ?? .close }

    /// The folder row's icon (an SF Symbol), beside its rows' own icons.
    public var symbol: String { RustActionCatalog.shared.folders[self]?.symbol ?? "folder" }

    /// Localized submenu title.
    public var title: String { RustActionCatalog.shared.folders[self]?.title ?? rawValue }
}
