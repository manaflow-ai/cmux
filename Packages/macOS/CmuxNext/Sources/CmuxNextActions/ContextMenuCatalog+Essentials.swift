/// What the app keeps of the crowded right-click menus' rules (Leo 2026-10-11: the workspace
/// menu's twelve rows were "overwhelming"). Rust builds the menus (cmux-action-catalog
/// `context_menus::ESSENTIALS`): the essential rows, the group section, More and the close rows.
nonisolated enum ContextMenuEssentials {
    /// A choices row's trailing action, shown under its own title after the choices: Move to Group
    /// lists the groups, then New Group (`context_menu_choice_trailers`).
    static var choiceTrailers: [ActionID: ActionID] { RustActionCatalog.shared.choiceTrailers }

    /// The most rows a folder inside More may have and still show as a section of More rather than
    /// a submenu of its own (cmux-action-catalog `INLINE_FOLDER_LIMIT`).
    static let inlineFolderLimit = 8
}
