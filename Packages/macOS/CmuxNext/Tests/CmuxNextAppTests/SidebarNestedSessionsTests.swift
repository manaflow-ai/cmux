import CmuxNextDesign
import CoreGraphics
@testable import CmuxNextSidebar
import Foundation
import Testing

/// `sidebar.nestedSessions` (Claude desktop's Code tab): a workspace's sub-sessions draw under its row, from the
/// Rust tree (`sidebar_session_tree`). Leo 2026-11-18: "make sure stuff is faithful + doesn't shift".
@MainActor @Suite struct SidebarNestedSessionsTests {
    static let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
    static let ws = (0..<4).map { SidebarWorkspace(id: WorkspaceID("w\($0)"), title: "Workspace \($0)") }

    static func sections() -> [SidebarSection] {
        [SidebarSection(kind: .machine(machine), nodes: ws.map { .workspace($0) })]
    }

    /// w1 has a running subagent (s1) that started another (s2), and a finished one (s3).
    static func nested(expanded: Set<String> = [], collapsed: Set<String> = [], byDefault: Bool = false) -> SidebarNestedSessionsState {
        SidebarNestedSessionsState(
            sessions: [WorkspaceID("w1"): [
                SidebarSubSession(id: "s1", title: "Fix the build", kind: "general-purpose", state: .running),
                SidebarSubSession(id: "s2", parentID: "s1", title: "Review it", state: .failed),
                SidebarSubSession(id: "s3", title: "Find the parser", kind: "Explore", state: .done),
            ]],
            expanded: expanded, collapsed: collapsed, expandedByDefault: byDefault)
    }

    static func layout(_ nested: SidebarNestedSessionsState?) -> SidebarLayout {
        var o = SidebarLayoutOptions()
        o.nestedSessions = nested
        return SidebarLayout.make(sections: sections(), metrics: .standard, options: o)
    }

    static func subRows(_ layout: SidebarLayout) -> [String] {
        layout.rows.compactMap { if case let .subSession(_, id) = $0.key { id } else { nil } }
    }

    @Test func offDrawsTheListAsBefore() {
        let off = Self.layout(nil)
        #expect(Self.subRows(off).isEmpty)
        #expect(off.rows.allSatisfy { $0.content?.treeFold == nil })
    }

    @Test func aFoldedParentShowsAChevronAndTheMostUrgentHiddenState() throws {
        let layout = Self.layout(Self.nested())
        #expect(Self.subRows(layout).isEmpty)
        let parent = try #require(layout.row(for: .workspace(WorkspaceID("w1"))))
        #expect(parent.content?.treeFold == .collapsed)
        #expect(parent.content?.activity == .error, "a failed sub-session beats a running one on the folded mark")
        #expect(layout.row(for: .workspace(WorkspaceID("w0")))?.content?.treeFold == nil)
    }

    @Test func anOpenParentDrawsItsSubSessionsInOrderAtTheirDepth() throws {
        let layout = Self.layout(Self.nested(expanded: ["ws:w1", "sub:w1:s1"]))
        #expect(Self.subRows(layout) == ["s1", "s2", "s3"])
        let parent = try #require(layout.row(for: .workspace(WorkspaceID("w1"))))
        #expect(parent.content?.treeFold == .expanded)
        let depths = layout.rows.compactMap { row -> Int? in if case .subSession = row.key { row.content?.treeDepth } else { nil } }
        #expect(depths == [1, 2, 1])
        // The sub-sessions sit right under their workspace, before the next one.
        let keys = layout.rows.map(\.key)
        let at = try #require(keys.firstIndex(of: .workspace(WorkspaceID("w1"))))
        #expect(keys[at + 1] == .subSession(WorkspaceID("w1"), "s1"))
        #expect(keys[at + 4] == .workspace(WorkspaceID("w2")))
    }

    /// No shift: opening a parent moves no row above it, keeps every row's height, and moves the rows below by the
    /// added rows' heights only.
    @Test func openingAParentMovesNothingAboveIt() throws {
        let folded = Self.layout(Self.nested())
        let open = Self.layout(Self.nested(expanded: ["ws:w1"]))
        for id in ["w0", "w1"] {
            let before = try #require(folded.row(for: .workspace(WorkspaceID(id))))
            let after = try #require(open.row(for: .workspace(WorkspaceID(id))))
            #expect(before.y == after.y && before.height == after.height, "\(id) stays put")
        }
        let added = open.rows.filter { if case .subSession = $0.key { true } else { false } }
        #expect(added.count == 2, "s2 stays folded under s1")
        let oneLine = SidebarLayoutMetrics.standard.height(for: WorkspaceRowContent())
        #expect(added.allSatisfy { $0.height == oneLine })
        let grow = added.reduce(CGFloat(0)) { $0 + $1.height + SidebarLayoutMetrics.standard.rowSpacing }
        for id in ["w2", "w3"] {
            let before = try #require(folded.row(for: .workspace(WorkspaceID(id))))
            let after = try #require(open.row(for: .workspace(WorkspaceID(id))))
            #expect(after.y - before.y == grow && before.height == after.height)
        }
    }

    @Test func expandedByDefaultOpensEveryParentTheUserDidNotFold() {
        #expect(Self.subRows(Self.layout(Self.nested(byDefault: true))) == ["s1", "s2", "s3"])
        #expect(Self.subRows(Self.layout(Self.nested(collapsed: ["sub:w1:s1"], byDefault: true))) == ["s1", "s3"])
        #expect(Self.subRows(Self.layout(Self.nested(collapsed: ["ws:w1"], byDefault: true))).isEmpty)
    }

    @Test func aFoldPersistsPerRowThroughTheRustModel() throws {
        let defaults = try #require(UserDefaults(suiteName: "SidebarNestedSessionsTests.\(UUID().uuidString)"))
        let model = SidebarNestedSessions(defaults: defaults)
        model.mode = .collapsed
        model.sessions = Self.nested().sessions
        #expect(model.fold("ws:w1") == true)
        #expect(model.expanded == ["ws:w1"])
        #expect(model.fold("ws:w1", open: true) == true, "Right on an open row keeps it open")
        #expect(model.fold("ws:w1") == false)
        #expect(model.expanded.isEmpty && model.collapsed.isEmpty, "back at the default keeps nothing")
        model.fold("sub:w1:s1")
        #expect(SidebarNestedSessions(defaults: defaults).expanded == ["sub:w1:s1"], "kept across launches")
        model.mode = .never
        #expect(model.drawn == nil)
    }
}
