/// What a Close Workspace reads of the window registry, counted for `WorkspaceCloseCountTests`: one close of a shown
/// workspace does work O(shown + changed), in a session of 826 workspaces as in one of 60 (CLAUDE.md "Go past
/// Chrome": a local model change is O(changed items), never O(session)). Plain adds on the main actor, kept by the
/// app's `WindowRegistryStore` (`closeWork`).
///
/// - `repairedWindows`: windows a selection repair visited (`WindowRegistryStore.repairs`).
/// - `repairedIDs`: the workspaces those windows list (each repair filters and searches its window's whole list).
/// - `showCalls`: runs of a window's `showWorkspace` (each asks which parked contents left the window).
/// - `shownIDs`: the workspace ids those runs read to answer that.
public nonisolated struct WorkspaceCloseWork: Equatable, Sendable, CustomStringConvertible {
    public var repairedWindows = 0
    public var repairedIDs = 0
    public var showCalls = 0
    public var shownIDs = 0

    public init() {}

    public var description: String {
        "repaired windows \(repairedWindows), repaired ids \(repairedIDs), show calls \(showCalls), shown ids \(shownIDs)"
    }
}
