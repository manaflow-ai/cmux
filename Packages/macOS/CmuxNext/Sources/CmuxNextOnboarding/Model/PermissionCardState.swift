/// What one Computer Use permission card shows on its right.
///
/// The cards keep the order of `ComputerUsePermissionPane.allCases`: the
/// first grant that is still missing is the next step and gets the filled
/// Allow; a later missing grant gets a bordered Allow. That order replaces the
/// old "1" and "2" key badges, which read as error counts (user 2026-10-27).
public nonisolated enum PermissionCardState: Equatable, Sendable {
    /// macOS has the grant: a green check and "Allowed".
    case granted
    /// The next grant to give: the filled (primary) Allow.
    case next
    /// A grant after the next one: a bordered Allow.
    case later

    /// The state of `pane`'s card for `permissions`.
    public init(pane: ComputerUsePermissionPane, permissions: ComputerUsePermissions) {
        if permissions.granted(pane) {
            self = .granted
            return
        }
        let firstMissing = ComputerUsePermissionPane.allCases.first { !permissions.granted($0) }
        self = firstMissing == pane ? .next : .later
    }
}
