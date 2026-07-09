import CMUXAgentLaunch
import Testing

@testable import CmuxNotifications

@Suite("NotificationFeedDecision workstream mapping")
struct NotificationFeedDecisionWorkstreamTests {
    @Test("permission modes map case-for-case")
    func permissionModesMap() {
        #expect(NotificationFeedPermissionMode.once.workstreamPermissionMode == .once)
        #expect(NotificationFeedPermissionMode.always.workstreamPermissionMode == .always)
        #expect(NotificationFeedPermissionMode.all.workstreamPermissionMode == .all)
        #expect(NotificationFeedPermissionMode.bypass.workstreamPermissionMode == .bypass)
        #expect(NotificationFeedPermissionMode.deny.workstreamPermissionMode == .deny)
    }

    @Test("exit-plan modes map case-for-case")
    func exitPlanModesMap() {
        #expect(NotificationFeedExitPlanMode.ultraplan.workstreamExitPlanMode == .ultraplan)
        #expect(NotificationFeedExitPlanMode.bypassPermissions.workstreamExitPlanMode == .bypassPermissions)
        #expect(NotificationFeedExitPlanMode.autoAccept.workstreamExitPlanMode == .autoAccept)
        #expect(NotificationFeedExitPlanMode.manual.workstreamExitPlanMode == .manual)
        #expect(NotificationFeedExitPlanMode.deny.workstreamExitPlanMode == .deny)
    }

    @Test("permission decision maps to a workstream permission decision")
    func permissionDecisionMaps() {
        #expect(NotificationFeedDecision.permission(.always).workstreamDecision == .permission(.always))
        #expect(NotificationFeedDecision.permission(.deny).workstreamDecision == .permission(.deny))
    }

    @Test("exit-plan decision maps with nil feedback")
    func exitPlanDecisionMaps() {
        #expect(
            NotificationFeedDecision.exitPlan(.ultraplan).workstreamDecision
                == .exitPlan(.ultraplan, feedback: nil)
        )
        #expect(
            NotificationFeedDecision.exitPlan(.manual).workstreamDecision
                == .exitPlan(.manual, feedback: nil)
        )
    }
}
