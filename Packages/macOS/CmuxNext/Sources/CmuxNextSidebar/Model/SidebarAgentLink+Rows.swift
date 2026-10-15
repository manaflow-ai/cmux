/// Elbow children in the App's row writer (`SidebarRows`): rows link to their parents only while
/// Group by Status nests them, so with the toggles off the list does no link work.
extension SidebarAgentLink {
    /// Whether rows nest under their parents (Debug `sidebar.groupByStatus` and `sidebar.statusElbow`).
    /// Off, nothing reads a lane: rows map as before and a lane change maps no row (review of #20905).
    @MainActor public static var nests: Bool { SidebarTunables.groupByStatus.value && SidebarTunables.statusElbow.value }

    /// The sections the list shows: `sections` linked (`linking`) while rows nest, else as they are.
    @MainActor public static func shown(_ sections: [SidebarSection]) -> [SidebarSection] {
        nests ? linking(sections) : sections
    }

    /// Writes `changed` into `live` and returns the rows to patch in place, their parents resolved
    /// while rows nest; nil when a row's agent sessions changed (`relinks`): it may be another
    /// row's parent, so every row is shown again.
    @MainActor public static func patching(_ changed: [SidebarWorkspace], in live: inout [SidebarSection]) -> [SidebarWorkspace]? {
        let nests = nests, relinks = nests && relinks(changed, in: live)
        live = SidebarSection.patching(changed, in: live)
        guard nests else { return changed }
        guard !relinks else { return nil }
        let parents = parents(in: live)
        return changed.map { row in
            var row = row
            row.parentWorkspace = parents[row.id]
            return row
        }
    }
}
