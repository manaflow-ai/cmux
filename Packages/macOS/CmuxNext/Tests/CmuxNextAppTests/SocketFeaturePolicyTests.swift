import CmuxNextActions
import CmuxNextControl
import Testing
@testable import CmuxNextApp

/// Socket methods outside the action registry follow DisabledFeatures
/// (enterprise.md P17-1b, coordinator decision 2026-10-03).
@Suite struct SocketFeaturePolicyTests {
    @Test func cloudOffRefusesMachineReadsAndCodeRouterWrites() {
        for method in ["cloud.machines", "coderouter.claude_upstream.add", "coderouter.claude_upstream.set",
                       "coderouter.claude_upstream.update", "coderouter.claude_upstream.remove", "coderouter.claude_upstream.clear"] {
            let refusal = AppControl.policyRefusal(method, disabled: [.cloud])
            #expect(refusal?.code == "feature.disabled", "\(method)")
            #expect(AppControl.policyRefusal(method, disabled: []) == nil, "\(method)")
        }
        #expect(AppControl.policyRefusal("remote.machines", disabled: [.remoteHosts])?.code == "feature.disabled")
    }

    /// CodeRouter reads stay, and phone access is not Cloud: the phone reaches this Mac.
    @Test func readsAndPhoneAccessStayOn() {
        let all = Set(ActionFeature.allCases)
        for method in ["coderouter.claude_upstream.get", "coderouter.machines", "coderouter.accounts.list",
                       "mobile.start", "mobile.attach_ticket.create", "auth.status"] {
            #expect(AppControl.policyRefusal(method, disabled: all) == nil, "\(method)")
        }
    }
}
