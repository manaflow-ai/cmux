/// The freeing tier's terminal reads and park (plans/cmux-next/sidebar-recents-and-freeing-DESIGN.md): what
/// ``WorkspaceHibernation`` asks of this Mac's daemon. ``LocalTerminalFreeing`` is the daemon's; tests pass a fake.
@MainActor
public protocol WorkspaceTerminalFreeing: AnyObject {
    /// The terminal tabs of `workspaces` (hibernated ones), with the facts that keep each shell running.
    func terminals(in workspaces: Set<String>) -> [WorkspaceFreeingPlanner.Terminal]
    /// Ends the shells of `surfaces` and keeps their tabs (`park-tabs`): showing one starts it again.
    func park(_ surfaces: [String])
}
