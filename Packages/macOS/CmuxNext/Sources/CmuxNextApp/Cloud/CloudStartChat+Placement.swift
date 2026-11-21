import CmuxNextBridge

extension CloudStartChat {
    /// Where a started Cloud chat's workspace goes (cmux#47677): right above the row the send began in,
    /// when the sidebar lists the two together; else first among its machine's rows. A Cloud machine's
    /// workspaces list in that machine's own section, which never holds this Mac's row, so `.above`
    /// alone resolved to nothing and the workspace kept its place at the sidebar's end.
    static func placementSlot(besides origin: String) -> WorkspaceSlot { .first([.above(origin), .top(anchor: nil)]) }

    /// The window that holds the send's workspace, whichever workspace it shows now: the person may
    /// have switched while the machine started, and the old lookup by selected workspace then placed nothing.
    @MainActor static func placementWindow(of workspace: String, services: AppServices) -> String? {
        services.windows.registry.value.owner(of: workspace)
            ?? services.windows.controllers.first(where: { $0.state.workspaceID == workspace })?.state.id
    }
}
