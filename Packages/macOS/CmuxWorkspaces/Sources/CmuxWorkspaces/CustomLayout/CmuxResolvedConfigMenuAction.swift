/// A fully-resolved entry in a button's right-click context menu: a
/// ``CmuxConfigContextMenuActionItem`` folded together with the
/// ``CmuxResolvedConfigAction`` it triggers, plus the concrete display values
/// (title, icon, tooltip) the menu renders directly.
///
/// Built once when a `cmux.json` button placement is resolved, then consumed by
/// the sidebar/header menus and the tab-bar context-menu runner. The `icon` is
/// the resolved ``CmuxButtonIcon``; `iconSourcePath` records the `cmux.json` path
/// the icon was declared in so a relative image asset can be located when the
/// menu is built app-side.
public struct CmuxResolvedConfigMenuAction: Identifiable, Sendable, Hashable {
    /// Stable identifier for the menu entry (derived from setting/index/action).
    public var id: String
    /// The resolved display title.
    public var title: String
    /// The resolved icon, if any.
    public var icon: CmuxButtonIcon?
    /// The `cmux.json` path the icon was declared in, used to locate relative assets.
    public var iconSourcePath: String?
    /// The resolved tooltip, if any.
    public var tooltip: String?
    /// The typed action this menu entry triggers.
    public var action: CmuxResolvedConfigAction

    /// Creates a resolved context-menu action.
    public init(
        id: String,
        title: String,
        icon: CmuxButtonIcon? = nil,
        iconSourcePath: String? = nil,
        tooltip: String? = nil,
        action: CmuxResolvedConfigAction
    ) {
        self.id = id
        self.title = title
        self.icon = icon
        self.iconSourcePath = iconSourcePath
        self.tooltip = tooltip
        self.action = action
    }
}
