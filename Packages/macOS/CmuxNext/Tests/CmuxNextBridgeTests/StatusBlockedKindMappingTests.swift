import CmuxNextDesign
import CmuxNextTabs
import Testing
@testable import CmuxNextBridge
@testable import CmuxNextDaemon

/// cx-kxa2: the OSC 7501 blocked kind (permission, question, auth) reaches the
/// indicator state the sidebar row and the tab badge draw, so a status icon
/// set can mark each kind apart.
@MainActor
struct StatusBlockedKindMappingTests {
    @Test func aBlockedQuestionReachesTheRowAndTheTab() throws {
        let store = try BridgeFixture.store()
        let workspace = try #require(store.sidebarSections.flatMap(\.workspaces).first { $0.displayName == "beta" })
        let tab = try #require(workspace.screens.flatMap(\.panes).flatMap(\.tabs).first)
        tab.programStatus = [ProgramStatusRecord(id: "ask", state: .blocked, kind: .question, title: "Which branch?", updatedSeq: 1)]
        #expect(StatusMapping.shared.summary(tab).state == .waiting(kind: .question))
        #expect(StatusMapping.shared.blockedKind(tab) == .question)
        #expect(SidebarMapping.shared.row(workspace, machine: .local).activity == .waiting(kind: .question))
        let item = TabItemMapping.shared.item(tab, fallbackTitle: "t")
        #expect(item.status == .needsInput)
        #expect(item.blockedKind == .question)
        // The plan of a candidate set sees the kind; the default set does not change.
        let state = SidebarMapping.shared.row(workspace, machine: .local).activity
        #expect(StatusIndicatorPlan.make(state, style: .arc, animates: true, set: .badges)
            != StatusIndicatorPlan.make(.waiting, style: .arc, animates: true, set: .badges))
        #expect(StatusIndicatorPlan.make(state, style: .arc, animates: true) == StatusIndicatorPlan.make(.waiting, style: .arc, animates: true))
    }

    @Test func eachKindMapsAndAnUnknownKindIsPlainBlocked() throws {
        let store = try BridgeFixture.store()
        let tab = try #require(store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs).first)
        for (kind, expected) in [(ProgramStatusRecord.Kind.permission, StatusBlockedKind.permission), (.question, .question), (.auth, .auth)] {
            tab.programStatus = [ProgramStatusRecord(state: .blocked, kind: kind, updatedSeq: 1)]
            #expect(StatusMapping.shared.summary(tab).state == .waiting(kind: expected))
        }
        tab.programStatus = [ProgramStatusRecord(state: .blocked, updatedSeq: 2)]
        #expect(StatusMapping.shared.summary(tab).state == .waiting(kind: nil))
        #expect(TabItemMapping.shared.item(tab, fallbackTitle: "t").blockedKind == nil)
        // An agent hook that blocks has no kind.
        tab.programStatus = []
        tab.setAgent(AgentStatus(surface: 1, state: .blocked))
        #expect(StatusMapping.shared.summary(tab).state == .waiting)
    }
}
