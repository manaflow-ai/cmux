import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// SIDEBAR ROW CHANGE stage 1 (WORKSPACE LIST 800, run 5: one closed row read each listed row 4 times, 3302 rows at
/// 826 workspaces; two of the four were the scroll rule's, which built a list of every row of the shown layout and of
/// the new one, and two sets of every id). One row closes or comes: the scroll rule reads the rows in view and the rows
/// beside the change, at 60 workspaces as at 826, and the list ends at the same offset as before.
///
/// Each case is one change (a close of a row in view, of one above the view, of the selected one, of the last one; a
/// new workspace's row at the press, selected) with the list at its top, its middle and its end.
///
///     swift test --filter SidebarRowChangeScrollTests
@MainActor @Suite(.serialized, .closesItsWindows) struct SidebarRowChangeScrollTests {
    typealias Insert = SidebarCreateInsertScalingTests
    typealias Item = ListViewport<SidebarRowKey>.Item
    typealias Reference = ListViewportReference<SidebarRowKey>

    static let sizes = [60, 826]

    enum Scroll: String, CaseIterable { case top, middle, end }
    enum Change: String, CaseIterable { case closeInView, closeAboveView, closeSelected, closeLast, create }

    /// What one case did: the rows the scroll rule read, the rows in view, and where the list ended against the rule.
    struct Outcome {
        var viewportRows: Int
        var inView: Int
        var offset: CGFloat
        var expected: CGFloat
        var started: CGFloat
    }

    private static func reference(_ layout: SidebarLayout, height: CGFloat) -> Reference {
        Reference(items: layout.rows.map { Item(id: $0.key, start: $0.y, length: $0.height) }, viewport: height,
                  content: max(layout.totalHeight, height))
    }

    private static func workspace(_ key: SidebarRowKey) -> WorkspaceID? {
        if case let .workspace(id) = key { id } else { nil }
    }

    /// Runs `change` in a list of `size` loose workspaces scrolled to `scroll`. Nil when the case does not exist
    /// there (no row is above the view of a list at its top).
    static func run(_ size: Int, _ scroll: Scroll, _ change: Change) throws -> Outcome? {
        let h = Insert.make(size)
        defer { h.window.close() }
        let list = h.sidebar.list
        let clip = try #require(list.enclosingScrollView?.contentView, "fixture: the list has no scroll view")
        let height = clip.bounds.height
        try #require(height > 100, "fixture: the list's viewport is \(height) pt tall")
        let end = max(0, list.displayed.totalHeight - height)
        try #require(end > 200, "fixture: \(size) rows scroll \(end) pt only")
        let start: CGFloat = switch scroll {
        case .top: 0
        case .middle: (end / 2).rounded()
        case .end: end
        }
        list.scrollClip(to: start, animated: false)
        try #require(abs(clip.bounds.minY - start) < 0.5, "fixture: the list is at \(clip.bounds.minY), not \(start)")
        // The workspace rows in view, in order, and each one's node index in the section.
        let inView = list.displayed.rows.filter { $0.maxY > start + 1 && $0.y < start + height - 1 }
        let shown = inView.compactMap { Self.workspace($0.key) }
        try #require(shown.count >= 6, "fixture: \(shown.count) workspace rows in view")
        let node = { (id: WorkspaceID) in
            h.rows.firstIndex { if case let .workspace(ws) = $0 { ws.id == id } else { false } }
        }
        var nodes = h.rows
        var select: WorkspaceID?
        switch change {
        case .closeInView:
            nodes.remove(at: try #require(node(shown[shown.count / 2])))
        case .closeAboveView:
            guard let first = node(shown[0]), first >= 2 else { return nil }
            nodes.remove(at: first / 2)
        case .closeSelected:
            // The selection stands on a row in view, as a person's does; its close moves it to the next row.
            let selected = shown[shown.count / 3]
            h.model.activeWorkspaceID = selected
            h.sidebar.renderNow()
            try #require(abs(clip.bounds.minY - start) < 0.5, "fixture: selecting a row in view scrolled the list")
            nodes.remove(at: try #require(node(selected)))
            select = shown[shown.count / 3 + 1]
        case .closeLast:
            nodes.removeLast()
        case .create:
            nodes.insert(.workspace(SidebarWorkspace(id: Insert.created, title: "new workspace", rowState: .creating)), at: 2)
            select = Insert.created
        }
        let before = Self.reference(list.displayed, height: height)
        let focused = list.revealedActive
        _ = SidebarPerfCounters.report(reset: true)
        h.model.setSections(Insert.sections(nodes))
        if let select { h.model.activeWorkspaceID = select }
        h.sidebar.renderNow()
        let counts = SidebarPerfCounters.report(reset: true)
        try #require(counts["list_reloads"] == 1, "fixture: \(counts["list_reloads"] ?? 0) list reloads for one change (\(change.rawValue))")
        let after = Self.reference(list.displayed, height: height)
        let expected = after.settle(from: before, offset: start, focused: focused, newFocus: list.selectionRevealKey,
                                    padding: SidebarLayout.revealPadding, userMoved: false,
                                    extent: list.selectionReveal(in: list.displayed, height: height))
        return Outcome(viewportRows: counts["viewport_rows"] ?? 0, inView: inView.count, offset: clip.bounds.minY,
                       expected: expected, started: start)
    }

    /// One run of the cases per size, for both tests.
    private static var measured: [Int: [String: Outcome]] = [:]

    /// Every case that exists, at `size`.
    static func outcomes(_ size: Int) throws -> [String: Outcome] {
        if let outcomes = measured[size] { return outcomes }
        var outcomes: [String: Outcome] = [:]
        try Motion.withReduceMotion {
            for scroll in Scroll.allCases {
                for change in Change.allCases {
                    if let outcome = try run(size, scroll, change) { outcomes["\(change.rawValue) at the \(scroll.rawValue)"] = outcome }
                }
            }
        }
        measured[size] = outcomes
        return outcomes
    }

    /// The scroll rule reads the rows in view of the shown list and of the new one, and the rows beside the change:
    /// never every listed row, and no more at 826 workspaces than at 60.
    @Test(.timeLimit(.minutes(10)))
    func oneChangedRowReadsTheRowsInViewForTheScroll() throws {
        var read: [Int: [String: Int]] = [:]
        for size in Self.sizes {
            let outcomes = try Self.outcomes(size)
            try #require(outcomes.count >= 14, "fixture: \(outcomes.count) cases ran at \(size)")
            for (name, outcome) in outcomes.sorted(by: { $0.key < $1.key }) {
                print("SidebarRowChangeScroll \(size) \(name): viewport_rows \(outcome.viewportRows), rows in view \(outcome.inView)")
                read[size, default: [:]][name] = outcome.viewportRows
                #expect(outcome.viewportRows > 0, "fixture: \(name) at \(size) read no row for the scroll (the counter is not wired)")
                #expect(outcome.viewportRows <= 2 * outcome.inView + 32,
                        "\(name) in a list of \(size): the scroll rule read \(outcome.viewportRows) rows, \(outcome.inView) are in view")
            }
        }
        for (name, small) in read[60] ?? [:] {
            let large = read[826]?[name] ?? 0
            #expect(large <= small + 8, "\(name): the scroll rule read \(small) rows at 60 workspaces and \(large) at 826")
        }
    }

    /// The list ends where the scroll rule of feat c7d588bf3df1 (`ListViewportReference`) puts it, in every case.
    @Test(.timeLimit(.minutes(10)))
    func oneChangedRowLeavesTheListWhereTheRuleBeforePutIt() throws {
        for size in Self.sizes {
            for (name, outcome) in try Self.outcomes(size).sorted(by: { $0.key < $1.key }) {
                print("SidebarRowChangeScroll \(size) \(name): offset \(outcome.started) -> \(outcome.offset), rule \(outcome.expected)")
                #expect(abs(outcome.offset - outcome.expected) <= 1,
                        "\(name) in a list of \(size): the list is at \(outcome.offset), the rule before puts it at \(outcome.expected) (from \(outcome.started))")
            }
        }
    }
}

private extension Motion {
    /// Runs `body` with Reduce Motion pinned on: every scroll and row move ends in the turn that starts it.
    @MainActor static func withReduceMotion<T>(_ body: () throws -> T) rethrows -> T {
        let previous = reduceMotionOverride
        reduceMotionOverride = true
        defer { reduceMotionOverride = previous }
        return try body()
    }
}
