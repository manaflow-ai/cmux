public import CmuxNextSidebar

/// A new workspace's sidebar row from the press until the window lists the workspace (the App's
/// `PendingWorkspaceRows` keeps them): drawn in its final look, under the workspace's own id, at its slot.
public struct PendingWorkspaceRow: Equatable {
    /// The workspace's key, fixed at the press.
    public let id: String
    public var window: String
    public let machine: MachineID
    /// The row as the window lists it once the daemon has created it.
    public let face: SidebarWorkspace
    /// Where it draws: the create's slot, or the one a drop of the row gave it (`dropped(at:in:)`).
    public var slot: WorkspaceSlot?
    public var byDefault: NewWorkspaceDefaultSlot?

    public init(id: String, window: String, machine: MachineID, face: SidebarWorkspace, slot: WorkspaceSlot?, byDefault: NewWorkspaceDefaultSlot?) {
        self.id = id
        self.window = window
        self.machine = machine
        self.face = face
        self.slot = slot
        self.byDefault = byDefault
    }

    /// The slot a drop of this row at `position` of `sections` (as drawn, this row included) gives its create: the
    /// drop's gap, by its neighbours, so rows that come or go before the workspace lands keep it where it was dropped.
    /// Nil off the row's own machine section: a workspace never changes machine.
    public func dropped(at position: DropPosition, in sections: [SidebarRowSection]) -> WorkspaceSlot? {
        guard position.section == .machine(machine), let gap = WorkspaceGap(position, in: sections, moving: [id]) else { return nil }
        return .gap(gap)
    }

    /// `sections` with each pending row the window does not list yet, at
    /// its slot (`NewWorkspaceDefaultSlot`), in press order. `home` is the
    /// home workspace's id. `catchingUp`: the window's `sections` are a projection behind the sidebar document
    /// (`SidebarRows.layoutCatchingUp`).
    public static func adding(_ rows: [PendingWorkspaceRow], to sections: [SidebarRowSection], home: String?, catchingUp: Bool) -> [SidebarRowSection] {
        guard !rows.isEmpty else { return sections }
        var sections = sections
        let listed = Set(sections.flatMap(\.workspaces).map(\.id.rawValue))
        for row in rows where !listed.contains(row.id) {
            let section = SectionID.machine(row.machine)
            // An explicit slot is ready at the press. A default slot whose
            // current anchor is missing belongs to the stale cold layout and
            // must wait for that anchor, rather than drawing a bottom frame.
            let slot: WorkspaceSlot?
            if let explicit = row.slot {
                slot = explicit
            } else if let byDefault = row.byDefault {
                // Before the slot: `top` resolves to the section's top without the current row, which may sit in a group.
                if byDefault.awaitsCurrentAnchor(section: section, in: sections, home: home, catchingUp: catchingUp) { continue }
                slot = byDefault.slot(for: row.id, section: section, in: sections, home: home, catchingUp: catchingUp) ?? .bottom(anchor: nil)
            } else {
                // No slot keeps the daemon's place: the end of the section.
                slot = .bottom(anchor: nil)
            }
            guard let slot, let position = slot.position(moving: [row.id], section: section, in: sections) else { continue }
            SidebarEdits.insert([row.face], at: position, in: &sections)
        }
        return sections
    }
}
