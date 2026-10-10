import CmuxNextBridge
import CmuxNextSettings
import CmuxNextSidebar

/// `workspaces.newPlacement` for one new workspace whose entry point names
/// no place (Cmd-N, the palette, the sidebar's +, `cmux workspace new`, a
/// tab moved to a new workspace). Resolved once the daemon reports the
/// workspace, against the sidebar of the window that lists it, and written
/// by the row-drag path (`SidebarBridge.place`): personal order in the home
/// session, else the owning daemon's order. Either survives a relaunch and
/// shows in every window.
///
/// The rule: `top` is the first slot of the workspace's machine section,
/// which lists no pinned workspace (they show in the Pinned section above),
/// above every group, and right below the home workspace's row when the list
/// shows it. `afterCurrent` is right after the workspace the window showed
/// when the new one was asked for, inside its group when it has one; `top`
/// when that workspace is not in the section (pinned, Home, another machine,
/// none). `bottom` leaves the daemon's place, the end of the loose rows.
struct NewWorkspaceDefaultSlot: Hashable, Sendable {
    var placement: NewWorkspacePlacement
    /// The workspace the window showed when the new one was asked for.
    var current: String?

    /// The slot for new workspace `id` in `section` of a window's `sections`;
    /// nil keeps the daemon's place. `home` is the home workspace's id.
    func slot(for id: String, section: SectionID, in sections: [SidebarRowSection], home: String?) -> WorkspaceSlot? {
        switch placement {
        case .bottom:
            return nil
        case .afterCurrent:
            if let current, current != id, current != home,
               WorkspaceSlot.below(current).position(moving: [id], section: section, in: sections) != nil {
                return .below(current)
            }
            return Self.top(for: id, section: section, in: sections, home: home)
        case .top:
            return Self.top(for: id, section: section, in: sections, home: home)
        }
    }

    /// First in the section, below a leading home row.
    private static func top(for id: String, section: SectionID, in sections: [SidebarRowSection], home: String?) -> WorkspaceSlot {
        let first = sections.first { $0.id == section }?.nodes.lazy.compactMap { node -> String? in
            guard case let .workspace(workspace) = node else { return "" }
            return workspace.id.rawValue == id ? nil : workspace.id.rawValue
        }.first
        if let home, first == home { return .below(home) }
        return .top(anchor: nil)
    }
}

/// Registering new workspaces for placement, outside `WindowManager` (its
/// type budget): the rule for a window, and the pending placement that
/// `WindowManager.applyPendingPlacements` resolves once the daemon reports
/// the workspace.
@MainActor
enum NewWorkspacePlacements {
    /// `workspaces.newPlacement` for a new workspace of window `windowID`
    /// (nil: the window reconcile gives it, the most recent open one), with
    /// the workspace that window shows now. Read it before the claim selects
    /// the new workspace.
    static func rule(for windowID: String?, in windows: WindowManager) -> NewWorkspaceDefaultSlot {
        let placement = windows.services.settings?.snapshot.newWorkspacePlacement ?? CmuxConfigSnapshot.newWorkspacePlacementFallback
        let window = windowID ?? windows.registry.value.mostRecentOpen()
        return NewWorkspaceDefaultSlot(placement: placement, current: window.flatMap { windows.states[$0]?.workspaceID })
    }

    /// Places workspace `id` at `slot`, else by `byDefault`, in window
    /// `windowID` (nil: the window that lists it): now when it is mirrored,
    /// else once the daemon reports it. `then` runs after, with the sidebar.
    static func expect(_ id: String, in windowID: String?, slot: WorkspaceSlot? = nil, byDefault: NewWorkspaceDefaultSlot?,
                       then: (@MainActor @Sendable (String, SidebarBridge) -> Void)? = nil, windows: WindowManager) {
        guard slot != nil || byDefault != nil || then != nil else { return }
        windows.pendingPlacements[id] = PendingPlacement(window: windowID, slot: slot, byDefault: byDefault, then: then)
        if windows.services.machines.workspace(id: id) != nil { windows.applyPendingPlacements(live: [id]) }
    }

    /// The local home workspace (`workspace-kind-v1`), whose row `top` stays below.
    static func home(_ machines: MachineRegistry) -> String? {
        machines.local.store.workspaces.first { $0.kind == SidebarMapping.homeKind }?.id
    }
}
