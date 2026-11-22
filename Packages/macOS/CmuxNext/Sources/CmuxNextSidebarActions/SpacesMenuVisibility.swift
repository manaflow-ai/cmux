public import CmuxNextActions
import CmuxNextSidebar

/// Keeps spaces out of the menus until the person has a second one, by the sidebar strip's own rule.
///
/// Lawrence 2026-11-20: "hide spaces by default, but people can still cmd shift p new space". With fewer than two
/// spaces (``ProfileBarLogic/isVisible(profileCount:)``) the Window menu shows no New, Previous or Next Space, the
/// sidebar's menu no New Space or New Incognito Space, and the workspace and group menus no Move or Duplicate to
/// Space. The command palette, the keys (the key router runs them before any menu), the CLI and MCP keep every
/// space action, so New Space is one Cmd-Shift-P away, and the space it makes brings every row back at the next look.
///
/// ```swift
/// SpacesMenuVisibility { spacesOfTheActiveWindow().count }.install(in: registry)
/// ```
@MainActor
public struct SpacesMenuVisibility {
    /// The menu rows that advertise spaces.
    static let menuRows: [ActionID] = [
        "space.new", "space.newIncognito", "space.previous", "space.next",
        "workspace.moveToSpace", "workspace.duplicateToSpace", "workspaceGroup.moveToSpace",
    ]

    private let spaceCount: @MainActor () -> Int

    /// - Parameter spaceCount: How many spaces the window the person acts in lists in its space bar (a normal
    ///   window lists no incognito space). Read each time a menu is built or opens.
    public init(spaceCount: @escaping @MainActor () -> Int) {
        self.spaceCount = spaceCount
    }

    /// Hides the space rows from every menu of `registry` while the person has fewer than two spaces.
    ///
    /// Call it after the space actions are bound: it decorates their bound actions.
    /// - Parameter registry: The app's action registry.
    public func install(in registry: ActionRegistry) {
        let spaceCount = spaceCount
        for id in Self.menuRows {
            ActionTargetVisibility.hideFromMenus(id, in: registry) { !ProfileBarLogic.isVisible(profileCount: spaceCount()) }
        }
    }
}
