import Foundation

/// Every workspace row of some sidebars, in order, each id once, as `Row`: kept while each sidebar's rows are the ones
/// it was read from (`SidebarModel.contentRevision`). The launch record lists them after every switch, which moves no
/// row, so it reads no row then (`SwitchSaveCostTests`).
@MainActor
package final class SidebarRowsCache<Row> {
    private var stamps: [Stamp] = []
    private var rows: [Row] = []
    /// Times every row was read, since it was made.
    package private(set) var builds = 0

    package init() {}

    nonisolated deinit {}

    package func rows(of models: [SidebarModel], _ row: (SidebarWorkspaceSnapshot) -> Row) -> [Row] {
        let now = models.map { Stamp(model: $0, revision: $0.contentRevision) }
        if builds > 0, stamps.elementsEqual(now, by: { $0.isSame(as: $1) }) { return rows }
        builds += 1
        var seen = Set<String>()
        rows = models.flatMap { model in
            let sidebar = SidebarSnapshot(sections: model.sections, profiles: model.profiles, activeProfileID: model.activeProfileID)
            return sidebar.sections.flatMap(\.nodes).flatMap { $0.workspace.map { [$0] } ?? $0.group?.workspaces ?? [] }
        }.filter { seen.insert($0.id).inserted }.map(row)
        stamps = now
        return rows
    }

    /// One sidebar and the revision of its rows. Weak, so a freed sidebar is never taken for a new one.
    private struct Stamp {
        weak var model: SidebarModel?
        var revision: UInt64

        func isSame(as other: Stamp) -> Bool {
            model != nil && model === other.model && revision == other.revision
        }
    }
}
