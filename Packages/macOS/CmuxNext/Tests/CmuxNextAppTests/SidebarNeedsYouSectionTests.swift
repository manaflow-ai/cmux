@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Foundation
import Testing

/// The Needs you section at the top of the sidebar (Leo 2026-11-10, design/sidebar.md "Per-project caps, infinite
/// scroll and Needs you"): yellow then blue rows from every project and loose workspace, at most 3, then "N more"; it
/// mirrors rows that stay in place; it folds; "N more" expands it inline and then reads "Show less". Rust orders and
/// caps it (`cmux-layout-reducer::sidebar_caps::needs_you`).
@MainActor @Suite(.serialized) struct SidebarNeedsYouSectionTests {
    static let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
    static let section = SectionID.machine(.local)

    static func ws(_ id: String, yellow: Bool = false, blue: Bool = false, working: Bool = false) -> SidebarWorkspace {
        var row = SidebarWorkspace(id: WorkspaceID(id), title: id)
        if yellow { row.agentChip = .needsYou }
        if blue { row.unread = .dot }
        if working { row.agentWorking = true }
        return row
    }

    static func w(_ id: String) -> SidebarRowKey { .workspace(WorkspaceID(id)) }
    static func n(_ id: String) -> SidebarRowKey { .needsYou(.row(WorkspaceID(id))) }

    /// Project p (p0 blue, p1 quiet, p2 yellow, p3 blue), then loose rows l0 (yellow), l1 (quiet), l2 (blue).
    static func sections(collapsed: Bool = false) -> [SidebarSection] {
        var project = SidebarGroup(id: GroupID("p"), name: "P", color: .green, workspaces: [
            ws("p0", blue: true), ws("p1"), ws("p2", yellow: true), ws("p3", blue: true),
        ])
        project.isCollapsed = collapsed
        let loose: [SidebarNode] = [.workspace(ws("l0", yellow: true)), .workspace(ws("l1")), .workspace(ws("l2", blue: true))]
        return [SidebarSection(kind: .machine(machine), nodes: [.group(project)] + loose)]
    }

    static func model(_ sections: [SidebarSection] = Self.sections(), caps: SidebarProjectCapsPreferences = .init(cap: 0, floats: false)) -> SidebarModel {
        let model = SidebarModel(sections: sections, activeWorkspaceID: nil)
        model.projectCaps = caps
        return model
    }

    static func layout(_ model: SidebarModel) -> SidebarLayout {
        SidebarLayout.make(sections: model.sections, metrics: .standard, options: model.listOptions())
    }

    static func keys(_ model: SidebarModel) -> [SidebarRowKey] {
        layout(model).rows.map(\.key).filter { if case .section = $0 { false } else { true } }
    }

    // MARK: Model: what Rust picks

    /// Yellow first, then blue, each in the sidebar's own order, from the project and the loose rows alike; at most 3.
    @Test func yellowThenBlueFromEveryProjectAndLooseRowAtMostThree() throws {
        let rows = try #require(Self.model().needsYouRows())
        #expect(rows.entries.map(\.workspace.id.rawValue) == ["p2", "l0", "p0"])
        #expect(rows.more == 2)
        #expect(rows.total == 5)
        #expect(!rows.isExpanded)
    }

    @Test func expandedListsEveryRowAndReadsShowLess() throws {
        let model = Self.model()
        model.needsYouExpanded = true
        let rows = try #require(model.needsYouRows())
        #expect(rows.entries.map(\.workspace.id.rawValue) == ["p2", "l0", "p0", "p3", "l2"])
        #expect(rows.more == 0)
        #expect(rows.isExpanded)
    }

    /// "Show less" only when there was something behind "N more".
    @Test func aShortSectionNeverReadsShowLess() throws {
        let model = Self.model([SidebarSection(kind: .machine(Self.machine), nodes: [.workspace(Self.ws("a", yellow: true))])])
        model.needsYouExpanded = true
        let rows = try #require(model.needsYouRows())
        #expect(rows.entries.count == 1)
        #expect(!rows.isExpanded)
        #expect(!rows.drawsMoreRow)
    }

    /// Working chats never move (Leo 2026-11-10); Include Working lists them after the blue ones.
    @Test func workingRowsListOnlyWithIncludeWorking() throws {
        let sections = [SidebarSection(kind: .machine(Self.machine), nodes: [
            .workspace(Self.ws("run", working: true)), .workspace(Self.ws("blue", blue: true)),
        ])]
        #expect(try #require(Self.model(sections).needsYouRows()).entries.map(\.workspace.id.rawValue) == ["blue"])
        let including = Self.model(sections, caps: .init(cap: 0, floats: false, includesWorking: true))
        #expect(try #require(including.needsYouRows()).entries.map(\.workspace.id.rawValue) == ["blue", "run"])
    }

    @Test func theSettingOffDrawsNoSection() {
        let model = Self.model(caps: .init(cap: 0, floats: false, needsYouSection: false))
        #expect(model.needsYouRows() == nil)
        #expect(!Self.keys(model).contains(.needsYou(.header)))
    }

    /// The rows Rust saw are found once per structural set; reads between, and folds, cost the drawn rows only.
    @Test func theRowsAreCachedByTheSectionsRevision() {
        let model = Self.model()
        _ = SidebarPerfCounters.report(reset: true)
        for _ in 0..<5 { _ = model.needsYouRows() }
        #expect(SidebarPerfCounters.report(reset: true)["needs_you_builds"] == 1)
        model.sections = Self.sections(collapsed: true)
        _ = model.needsYouRows()
        _ = model.needsYouRows()
        #expect(SidebarPerfCounters.report(reset: true)["needs_you_builds"] == 1)
        // A project's fold moves no row: it walks no row either, and the folded project's rows still list.
        #expect(model.setGroupCollapsed(GroupID("p"), false))
        #expect(model.needsYouRows()?.entries.first?.workspace.id == WorkspaceID("p2"))
        #expect(SidebarPerfCounters.report(reset: true)["needs_you_builds"] == nil)
    }

    /// A cached answer still draws each row's content now: a title patch keeps the revision and moves no row.
    @Test func aPatchedTitleShowsInTheSection() throws {
        let model = Self.model()
        _ = model.needsYouRows()
        var renamed = Self.ws("p2", yellow: true)
        renamed.title = "Renamed"
        #expect(model.patchWorkspaces([renamed]))
        #expect(try #require(model.needsYouRows()).entries.first?.workspace.title == "Renamed")
    }

    /// A row turning yellow or blue changes the section: the patch is a structural set (the list lays out again).
    @Test func aRowTurningYellowOrBlueMovesRows() {
        let model = Self.model()
        #expect(!model.patchWorkspaces([Self.ws("p1", yellow: true)]))
        #expect(!model.patchWorkspaces([Self.ws("l0")]))
        // Working alone moves nothing unless Include Working is on.
        #expect(model.patchWorkspaces([Self.ws("l1", working: true)]))
        let off = Self.model(caps: .off)
        #expect(off.patchWorkspaces([Self.ws("p1", yellow: true)]))
    }

    // MARK: Layout

    /// The section heads the list; its rows have their own keys, and every row stays in place below with its own.
    @Test func theSectionHeadsTheListAndMirrorsRowsThatStayInPlace() throws {
        let model = Self.model()
        #expect(Self.keys(model) == [
            .needsYou(.header), Self.n("p2"), Self.n("l0"), Self.n("p0"), .needsYou(.more),
            .group(GroupID("p")), Self.w("p0"), Self.w("p1"), Self.w("p2"), Self.w("p3"), Self.w("l0"), Self.w("l1"), Self.w("l2"),
        ])
        let layout = Self.layout(model)
        let more = try #require(layout.row(for: .needsYou(.more)))
        #expect(more.childCount == 2)
        #expect(more.isCollapsed)
        #expect(try #require(layout.row(for: .needsYou(.header))).childCount == 5)
        // The in-place rows sit below the section, after a section's spacing.
        let project = try #require(layout.row(for: .group(GroupID("p"))))
        #expect(project.y > more.maxY)
    }

    /// A collapsed project's yellow and blue rows still list at the top.
    @Test func aCollapsedProjectsRowsStillList() {
        let keys = Self.keys(Self.model(Self.sections(collapsed: true)))
        #expect(keys.prefix(4) == [.needsYou(.header), Self.n("p2"), Self.n("l0"), Self.n("p0")])
        #expect(!keys.contains(Self.w("p2")))
    }

    @Test func expandedTheSectionEndsInShowLess() throws {
        let model = Self.model()
        model.needsYouExpanded = true
        #expect(Array(Self.keys(model).prefix(7)) == [
            .needsYou(.header), Self.n("p2"), Self.n("l0"), Self.n("p0"), Self.n("p3"), Self.n("l2"), .needsYou(.more),
        ])
        let more = try #require(Self.layout(model).row(for: .needsYou(.more)))
        #expect(!more.isCollapsed)
        #expect(more.childCount == 0)
    }

    @Test func foldedTheSectionIsItsHeader() throws {
        let model = Self.model()
        model.needsYouFolded = true
        let keys = Self.keys(model)
        #expect(keys.first == .needsYou(.header))
        #expect(keys.dropFirst().first == .group(GroupID("p")))
        let header = try #require(Self.layout(model).row(for: .needsYou(.header)))
        #expect(header.isCollapsed)
        #expect(header.childCount == 5)
    }

    @Test func nothingWaitingDrawsNoSection() {
        let quiet = [SidebarSection(kind: .machine(Self.machine), nodes: [.workspace(Self.ws("a")), .workspace(Self.ws("b"))])]
        let model = Self.model(quiet)
        #expect(model.needsYouRows()?.isEmpty == true)
        #expect(Self.keys(model) == [Self.w("a"), Self.w("b")])
    }

    /// A filter shows matches where they are; the session tree has its own tray; Group by Status its own section.
    @Test func aFilterTheTreeAndGroupByStatusDrawNoSection() {
        let model = Self.model()
        var o = model.listOptions()
        o.filterMatches = [WorkspaceID("p2")]
        #expect(!SidebarLayout.make(sections: model.sections, metrics: .standard, options: o).rows.contains { $0.key == .needsYou(.header) })
        var status = model.listOptions()
        status.grouping.setByStatus(true)
        #expect(!SidebarLayout.drawsNeedsYouSection(status))
    }

    /// The drop resolver never reads a Needs you row: a drop lands where the rows in place say.
    @Test func dropsReadOnlyTheRowsInPlace() {
        let resolvable = RustRow.resolvable(Self.layout(Self.model()).rows)
        #expect(!resolvable.contains { $0.key.kind == "needs_you" })
        #expect(resolvable.filter { $0.key.kind == "workspace" }.count == 7)
    }

    @Test func theMoreRowSaysHowMany() {
        #expect(Strings.needsYouMore(2).contains("2"))
    }
}
