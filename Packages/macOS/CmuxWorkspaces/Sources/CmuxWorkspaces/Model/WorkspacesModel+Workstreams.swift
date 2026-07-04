public import Foundation

extension WorkspacesModel {
    /// Look up a workstream by id.
    public func workstream(id: UUID) -> Workstream? {
        workstreams.first { $0.id == id }
    }

    /// Member workspace ids of a workstream, in `tabs` order (the same
    /// convention `WorkspaceGroup` uses: membership order == tab order).
    public func memberWorkspaceIds(ofWorkstream workstreamId: UUID) -> [UUID] {
        tabs.filter { $0.workstreamId == workstreamId }.map(\.id)
    }

    /// Number of workspaces assigned to a workstream.
    public func memberCount(ofWorkstream workstreamId: UUID) -> Int {
        tabs.reduce(into: 0) { partial, tab in
            if tab.workstreamId == workstreamId { partial += 1 }
        }
    }

    /// The workspaces the sidebar should show given the current drill-in state.
    ///
    /// This is the entire drill-in filter, and it is deliberately a single
    /// predicate: `tab.workstreamId == drilledInWorkstreamId`.
    /// - At the top level (`drilledInWorkstreamId == nil`) it selects every
    ///   workspace not in any workstream — so a user with no workstreams sees
    ///   exactly today's flat list (zero regression).
    /// - Drilled into workstream `X` it selects only workspaces whose
    ///   `workstreamId == X`.
    public func tabsVisibleInSidebar() -> [Tab] {
        tabs.filter { $0.workstreamId == drilledInWorkstreamId }
    }

    /// Re-establish workstream invariants after any mutation that could leave
    /// dangling references:
    /// - clear `workstreamId` on workspaces whose workstream no longer exists;
    /// - clear `drilledInWorkstreamId` if it points at a removed workstream.
    ///
    /// Idempotent and side-effect-free when everything is already consistent,
    /// so it is safe to call from restore and from every coordinator mutation.
    public func normalizeWorkstreamState() {
        let knownIds = Set(workstreams.map(\.id))
        for tab in tabs where tab.workstreamId.map({ !knownIds.contains($0) }) ?? false {
            tab.workstreamId = nil
        }
        if let drilled = drilledInWorkstreamId, !knownIds.contains(drilled) {
            drilledInWorkstreamId = nil
        }
    }
}
