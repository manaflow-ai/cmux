/// Rows of workspaces a window keeps while no machine lists them (P-AUSTIN B7: a Cloud workspace
/// while signed out of cmux Cloud, Cloud turned off, its machine paused or not loaded yet). Each
/// row goes in its machine's section, after that section's rows; a machine with no section gets one,
/// after the others, headed by `header`. A row any section lists already is left out, so a
/// machine's own or saved rows always win.
nonisolated extension SidebarSection {
    public static func adding(absent rows: [SidebarWorkspace], header: (MachineID) -> SidebarMachine,
                       to sections: [SidebarSection]) -> [SidebarSection] {
        guard !rows.isEmpty else { return sections }
        var sections = sections
        let listed = Set(sections.flatMap(\.workspaces).map(\.id))
        for row in rows where !listed.contains(row.id) {
            if let index = sections.firstIndex(where: { $0.machine?.id == row.machineID }) {
                sections[index].nodes.append(.workspace(row))
            } else {
                sections.append(SidebarSection(kind: .machine(header(row.machineID)), nodes: [.workspace(row)]))
            }
        }
        return sections
    }
}
