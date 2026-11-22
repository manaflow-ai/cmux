import AppKit
import CmuxNextAgentActivity
import CmuxNextBridge
@testable import CmuxNextDaemon
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
@testable import CmuxNextAgentLanes
import Testing

/// Leo: "they even show chief-operated chats". Ownership comes from the existing acpmux tags; since
/// 2026-11-02 the row draws no Chief face (the transcript says who sent a message instead).
@MainActor @Suite(.serialized) struct SidebarChiefAvatarTests {
    private func lane(_ id: String, tags: [String: String] = [:], title: String = "Chat") throws -> AgentActivityLane {
        try #require(AgentActivityLane.of(summary: ["sessionId": id, "name": title, "tags": tags, "lane": ["state": "idle"]]))
    }

    @Test func namedChiefIdentityComesFromTagsAndDisappearsWhenOwnershipIsRemoved() throws {
        let lanes = AgentLaneStore()
        lanes.lanes = ["turn": try lane("turn", tags: ["mux.children": "optchat-chief:home", "cmux.chief.participant": "agent_scout"])]
        #expect(lanes.chiefParticipants["optchat-chief:home"] == "agent_scout")
        lanes.lanes["turn"] = try lane("turn", title: "Chief Scout")
        #expect(lanes.chiefParticipants.isEmpty, "a Chief-like name does not establish ownership")
    }

    @Test func onlyTheOwnedChatGetsItsChiefsFaceEvenWithLaneStatusOff() throws {
        let fixture = try SidebarLaneStatusTests.Fixture()
        fixture.lanes.lanes["chief-turn"] = try lane("chief-turn", tags: ["mux.children": "optchat-chief:home", "cmux.chief.participant": "agent_scout"])
        fixture.lanes.lanes["s-idle"] = try lane("s-idle", tags: ["mux.parent": "optchat-chief:home"])
        fixture.lanes.lanes["s-working"] = try lane("s-working", title: "Chief-controlled chat")
        SidebarLaneStatusTests.withLaneStatus(false) {
            let source = SidebarLaneStatus.applying(nil, lanes: fixture.lanes, turns: fixture.turns, chiefLanes: AgentLaneStore(),
                                                   chiefAvatar: { .text($0) })
            let sections = SidebarMapping.shared.sections(fixture.store.sidebarSections,
                machine: SidebarMachine(id: .local, name: "This Mac", kind: .local), rowSource: source)
            let rows = sections.flatMap(\.workspaces)
            #expect(rows.first { $0.title == "idle" }?.chiefAvatar == .text("agent_scout"))
            #expect(rows.filter { $0.title != "idle" }.allSatisfy { $0.chiefAvatar == nil })
        }
    }

    /// Leo, 2026-11-02, beside ChatGPT's "Sent from" line: "i don't think we necessarily want these
    /// chief-operated ones looking like this". A Chief-operated row draws like any other row: its unread
    /// dot and spinner take the trailing column, and no Chief face is drawn or read.
    @Test(arguments: SidebarRowBadgeStyle.allCases)
    func chiefOperatedRowLooksLikeAnyOtherRow(_ style: SidebarRowBadgeStyle) throws {
        let (model, sidebar, window) = SidebarRowCloseSpotTests.sidebar()
        defer { window.close() }
        var workspace = SidebarWorkspace(id: SidebarRowCloseSpotTests.shown, title: "Chief task", unread: .dot)
        workspace.chiefAvatar = .text("SC")
        model.sections = [SidebarSection(kind: .machine(SidebarMachine(id: .local, name: "This Mac", kind: .local)), nodes: [.workspace(workspace)])]
        model.rowBadgeStyle = style
        sidebar.list.reload(animated: false)
        sidebar.layoutSubtreeIfNeeded()
        let row = try #require(sidebar.list.rowViews[.workspace(workspace.id)] as? WorkspaceRowView)
        row.isHovered = false
        row.needsLayout = true
        row.layoutSubtreeIfNeeded()
        #expect(row.subviews.allSatisfy { !String(describing: type(of: $0)).contains("Chief") })
        #expect(row.accessibilityLabel()?.contains("Operated by Chief") != true)
        #expect(!(style == .trailing ? row.badge as NSView : row.rowBadge).isHidden, "the unread dot still shows")
    }

    @Test func workingSpinnerTakesTheTrailingColumnOnAChiefOperatedRow() throws {
        let (model, sidebar, window) = SidebarRowCloseSpotTests.sidebar()
        defer { window.close() }
        var workspace = SidebarWorkspace(id: SidebarRowCloseSpotTests.shown, title: "Chief task")
        workspace.activity = .working
        workspace.agentWorking = true
        workspace.chiefAvatar = .text("SC")
        model.sections = [SidebarSection(kind: .machine(SidebarMachine(id: .local, name: "This Mac", kind: .local)), nodes: [.workspace(workspace)])]
        model.rowBadgeStyle = .trailing
        sidebar.list.reload(animated: false)
        sidebar.layoutSubtreeIfNeeded()
        let row = try #require(sidebar.list.rowViews[.workspace(workspace.id)] as? WorkspaceRowView)
        row.isHovered = false
        row.needsLayout = true
        row.layoutSubtreeIfNeeded()
        #expect(row.activity.showsGlyph)
        // statusGlyphFrame rounds to the nearest backing pixel (including the half-pixel tie).
        #expect(abs(row.activity.frame.midX - SidebarStyle.trailingColumnCenterX(rowWidth: row.bounds.width)) <= 0.5 / window.backingScaleFactor)
    }
}
