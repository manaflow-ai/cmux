import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// SIDEBAR ROW CHANGE stage 2: with the change as the input (`SidebarModel.apply(_:)`), one closed or one new loose
/// row makes the model and the list read the changed row, the two rows beside it and the rows in view: the same count
/// in a list of 60 rows as in one of 826 (`rows_walked`). The full set (`SidebarModel.setSections`) reads every listed
/// row twice for it (the set, then the list's splice compare): 156 rows at 60 and 1688 at 826 after stage 1.
///
/// Each case is one change through the entry and the list's reload of it; the shown layout must be the full layout of
/// the model's rows, and the list's row caches must hold the change.
///
///     swift test --filter SidebarRowChangeEntryCountTests
@MainActor @Suite(.serialized, .closesItsWindows) struct SidebarRowChangeEntryCountTests {
    typealias Insert = SidebarCreateInsertScalingTests

    static let sizes = [60, 826]
    /// Rows read beside the rows in view: the changed row (the model) and the two rows beside its place (the list).
    static let constant = 8

    enum Case: String, CaseIterable, Sendable { case close, closeSelected, create }

    struct Outcome {
        var took: Bool
        var counts: [String: Int]
        var faults: [String]
    }

    /// One change in a list of `size` loose rows: by the entry, and by the full set when the entry refuses.
    static func run(_ size: Int, _ which: Case) -> Outcome {
        let h = Insert.make(size)
        defer { h.window.close() }
        let list = h.sidebar.list
        let section = SectionID.machine(.local)
        // The rows come by a full set, as the app's: the model counts each workspace's listings in it.
        h.model.setSections(Insert.sections(h.rows))
        h.sidebar.renderNow()
        var nodes = h.rows
        let change: SidebarLooseRowChange
        var selects: WorkspaceID?
        var gone: WorkspaceID?
        var new: SidebarWorkspace?
        switch which {
        case .close:
            nodes.remove(at: 7)
            gone = WorkspaceID("ci-7")
            change = .removed(WorkspaceID("ci-7"), section: section, node: 7)
        case .closeSelected:
            // `Insert.make` selects the second row; the row after it takes the selection, as a close's repair does.
            nodes.remove(at: 1)
            gone = WorkspaceID("ci-1")
            change = .removed(WorkspaceID("ci-1"), section: section, node: 1)
            selects = WorkspaceID("ci-2")
        case .create:
            let ws = SidebarWorkspace(id: Insert.created, title: "new workspace", rowState: .creating)
            nodes.insert(.workspace(ws), at: 2)
            new = ws
            change = .added(ws, section: section, node: 2)
            selects = Insert.created
        }
        _ = SidebarPerfCounters.report(reset: true)
        let took = h.model.apply(change)
        if !took { h.model.setSections(Insert.sections(nodes)) }
        if let selects { h.model.activeWorkspaceID = selects }
        h.sidebar.renderNow()
        let counts = SidebarPerfCounters.report(reset: true)
        var faults: [String] = []
        if h.model.sections != Insert.sections(nodes) { faults.append("the model's rows are not the rows with the change") }
        if list.displayed != Insert.fullLayout(h) { faults.append("the shown layout is not the full layout of the model's rows") }
        if list.sections[section] != h.model.sections.first { faults.append("the list's section cache is not the model's section") }
        if let gone, list.workspaces[gone] != nil { faults.append("the list's workspace cache holds the closed row") }
        if let new, list.workspaces[new.id] != new { faults.append("the list's workspace cache has no new row") }
        return Outcome(took: took, counts: counts, faults: faults)
    }

    @Test(arguments: Case.allCases)
    func oneRowChangeReadsTheChangedRowAndTheRowsInView(_ which: Case) {
        var walked: [Int: Int] = [:]
        for size in Self.sizes {
            let outcome = Self.run(size, which)
            let count = { (name: String) in outcome.counts[name] ?? 0 }
            let (rows, view) = (count("rows_walked"), count("viewport_rows"))
            walked[size] = rows
            // Every count, also when the test passes.
            print("SIDEBAR-ROW-CHANGE-ENTRY count case=\(which.rawValue) size=\(size) took=\(outcome.took) rows_walked=\(rows) viewport_rows=\(view)"
                + " section_sets=\(count("section_sets")) row_changes=\(count("row_changes")) list_reloads=\(count("list_reloads"))"
                + " layout_rows=\(count("layout_rows")) order_builds=\(count("order_builds")) row_index_builds=\(count("row_index_builds"))"
                + " row_listing_reads=\(count("row_listing_reads")) rebuilds=\(count("rebuilds"))")
            #expect(outcome.took, "\(which.rawValue) at \(size) rows: the entry refused a loose row listed once, with no filter")
            #expect(count("list_reloads") >= 1, "fixture: \(which.rawValue) at \(size) rows reloaded no list")
            #expect(outcome.faults.isEmpty, "\(which.rawValue) at \(size) rows: \(outcome.faults)")
            #expect(count("layout_rows") <= 2, "\(which.rawValue) at \(size) rows laid out \(count("layout_rows")) rows")
            #expect(count("row_listing_reads") == 0, "\(which.rawValue) at \(size) rows counted the listings of \(count("row_listing_reads")) workspaces again")
            #expect(count("section_sets") == 0, "\(which.rawValue) at \(size) rows set the sections \(count("section_sets")) times")
            // A change of the selection reads the selected rows' places (`SidebarListView+SelectionPatch`), which builds
            // the model's row index again after any structural set: every row, once. Not in `rows_walked`; a close of
            // a row that is not selected must build none.
            if which == .close {
                #expect(count("row_index_builds") == 0, "a close at \(size) rows built the row index (every row) \(count("row_index_builds")) times")
            }
            #expect(rows <= view + Self.constant,
                    "\(which.rawValue) at \(size) rows read \(rows) rows: more than the \(view) in view and \(Self.constant)")
        }
        let (small, large) = (walked[60] ?? 0, walked[826] ?? 0)
        #expect(abs(large - small) <= 4, "\(which.rawValue) reads \(small) rows at 60 and \(large) at 826")
    }
}
