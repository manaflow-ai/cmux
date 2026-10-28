/// The leading icon of a menu bar menu row (``MenuBarMenuSpec``), drawn as a monochrome template
/// as Raycast's menu draws its icons.
public nonisolated enum MenuBarMenuIcon: Sendable, Hashable {
    /// An SF Symbol, by name (`"info.circle"`).
    case symbol(String)
    /// A community service's mark, where no SF Symbol exists.
    case brand(MenuBarBrand)
}
