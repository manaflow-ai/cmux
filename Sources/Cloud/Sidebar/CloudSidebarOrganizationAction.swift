/// One organization command shared by context menus, native drops, notifications,
/// and socket clients. Relative moves name identities, never stale row offsets.
enum CloudSidebarOrganizationAction: Equatable {
    case pin, unpin, up, down, top
    case before(String), after(String)
}
