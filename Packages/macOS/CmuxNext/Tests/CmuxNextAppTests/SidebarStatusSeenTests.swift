import CmuxNextBridge
@testable import CmuxNextDaemon
@testable import CmuxNextDesign
import Testing

/// Every workspace-row status uses the same seen key and revision, so opening
/// a workspace clears the symbol at any sidebar width without changing the
/// daemon's report.
@MainActor @Suite struct SidebarStatusSeenTests {
    static let workspace = "ws-seen"

    static func report(_ state: StatusIndicatorState, label: String = "status") -> StatusReport {
        StatusReport(id: "status:entry", source: .explicit, state: state, label: label)
    }

    @Test(arguments: [StatusIndicatorState.error, .waiting, .success, .busy(progress: nil), .paused(progress: nil), .working])
    func everyRowStateClearsAfterItIsSeen(_ state: StatusIndicatorState) {
        let store = SidebarStatusSeenStore()
        let report = Self.report(state)
        #expect(store.visible([report], workspaceID: Self.workspace).count == 1)
        store.markSeen([report], workspaceID: Self.workspace)
        #expect(store.visible([report], workspaceID: Self.workspace).isEmpty)
    }

    @Test func aReportThatWentAwayIsForgotten() {
        let store = SidebarStatusSeenStore()
        let report = Self.report(.error)
        store.markSeen([report], workspaceID: Self.workspace)
        store.markSeen([], workspaceID: Self.workspace)
        #expect(store.visible([report], workspaceID: Self.workspace) == [report])
    }

    @Test func aChangedReportIsUnseenAgain() {
        let store = SidebarStatusSeenStore()
        let old = Self.report(.error, label: "old failure")
        store.markSeen([old], workspaceID: Self.workspace)
        let replacement = Self.report(.error, label: "new failure")
        #expect(store.visible([replacement], workspaceID: Self.workspace) == [replacement])
    }

    @Test func workspacesHaveIndependentSeenState() {
        let store = SidebarStatusSeenStore()
        let report = Self.report(.error)
        store.markSeen([report], workspaceID: Self.workspace)
        #expect(store.visible([report], workspaceID: "ws-other") == [report])
    }

    @Test func mappingUsesTheWorkspaceSeenRevision() {
        let store = SidebarStatusSeenStore()
        let mapping = StatusMapping(turns: AgentTurnStateStore(), seen: ProgramStatusSeenStore(), statusSeen: store)
        let status = WorkspaceStatus(workspaceID: ResourceID(rawValue: Self.workspace),
                                     entries: [WorkspaceStatus.Entry(key: "entry", text: "Failed", state: "error")])
        let tabs: [TabModel] = []
        #expect(mapping.summary(tabs: tabs, status: status, workspaceID: Self.workspace).state == .error)
        mapping.markSeen(tabs: tabs, status: status, workspaceID: Self.workspace)
        #expect(mapping.summary(tabs: tabs, status: status, workspaceID: Self.workspace).state == .idle)
    }
}
