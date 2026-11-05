@testable import CmuxNextActions
import Testing

/// Archive counterparts of the workspace row's several-at-once closes (user, 2026-11-05: "we need
/// archive workspaces below/above etc"): Archive Other Workspaces, Archive Workspaces Below, Archive
/// Workspaces Above and Archive Other Workspaces in Group, worded and ordered as their close rows, in
/// the row menu's Close section, Cmd-Shift-P, the CLI and MCP.
@MainActor @Suite struct BulkArchiveSurfacesTests {
    nonisolated static let pairs: [(archive: ActionID, close: ActionID, title: String)] = [
        ("workspace.archiveOtherWorkspaces", "palette.closeOtherWorkspaces", "Archive Other Workspaces"),
        ("workspace.archiveOthersInGroup", "workspace.closeOthersInGroup", "Archive Other Workspaces in Group"),
        ("workspace.archiveWorkspacesBelow", "palette.closeWorkspacesBelow", "Archive Workspaces Below"),
        ("workspace.archiveWorkspacesAbove", "palette.closeWorkspacesAbove", "Archive Workspaces Above"),
    ]

    @Test(arguments: pairs.map(\.archive))
    func eachArchiveRowIsOnEverySurfaceItsCloseRowIs(_ id: ActionID) throws {
        let descriptor = try #require(ActionCatalog.all.first { $0.id == id }, "\(id) is no catalog action")
        let pair = try #require(Self.pairs.first { $0.archive == id })
        #expect(descriptor.title == pair.title)
        #expect(descriptor.targets == [.workspace], "\(id) acts on a workspace row")
        #expect(!descriptor.isDestructive, "\(id): archiving is undoable and loses nothing")
        let plan = descriptor.surfacePlan
        #expect(plan.palette.isOffered, "\(id): not in Cmd-Shift-P")
        #expect(plan.cli?.isOffered == true, "\(id): no CLI verb")
        #expect(plan.mcp?.isOffered == true, "\(id): no MCP tool")
    }

    /// The row menu lists them in the close rows' order, after the close rows.
    @Test func theRowMenuListsThemAfterTheCloseRowsInTheSameOrder() throws {
        let shown = ContextMenuCatalog.shared.referencedIDs(ContextMenuCatalog.shared.entries(for: .workspaceRow))
        let rowPairs = Self.pairs.filter { shown.contains($0.close) }
        #expect(rowPairs.count == 4, "the row menu has Close Other, Other in Group, Below and Above")
        let closes = try rowPairs.map { pair in try #require(shown.firstIndex(of: pair.close)) }
        let archives = try rowPairs.map { pair in try #require(shown.firstIndex(of: pair.archive), "\(pair.archive) is not in the row menu") }
        #expect(closes == closes.sorted(), "the close rows keep their order")
        #expect(archives == archives.sorted(), "archive rows are not in the close rows' order")
        #expect((archives.min() ?? 0) > (closes.max() ?? 0), "archive rows come after the close rows")
    }
}
