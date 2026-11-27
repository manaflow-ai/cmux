/// Sidebars to redraw in the turn something they draw over their shown rows changes (the App's
/// PendingWorkspaceRows: a create's row from its press), with no rows pass walking every workspace
/// on a later hop (debug.new_workspace `walks` 0). Each redraw runs while its owner lives.
@MainActor
public final class SidebarRedraws {
    private struct Entry {
        weak var owner: AnyObject?
        let redraw: @MainActor () -> Void
    }

    private var entries: [Entry] = []

    public init() {}

    /// Runs `redraw` at each `run()` while `owner` lives (again for the same owner replaces it).
    public func add(_ owner: AnyObject, _ redraw: @escaping @MainActor () -> Void) {
        entries.removeAll { $0.owner == nil || $0.owner === owner }
        entries.append(Entry(owner: owner, redraw: redraw))
    }

    /// Runs every live owner's redraw now.
    public func run() {
        entries.removeAll { $0.owner == nil }
        for entry in entries { entry.redraw() }
    }
}
