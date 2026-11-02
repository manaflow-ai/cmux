import CmuxNextComputerUse
import CmuxNextMacScreen
import CmuxNextMobileHost
import CmuxNextSettings

extension AppServices {
    /// Computer Use app approvals (docs/computer-use-approvals.md): the worker's questions, the
    /// cards, and the owner's iPhone through the iPhone host (its answers are checked against
    /// this Mac's own paired keys).
    func startComputerUseApprovals(_ settings: SettingsController) {
        let approvals = computerUseApprovals, iphone = iphone
        approvals.start(helper: ComputerUseHelperDaemon.shared.upstream, settings: settings)
        approvals.connectPhone(ask: { iphone.computerUseAsk(digest: $0.digest, request: $0.foundationObject, always: $1) },
                               done: { iphone.computerUseDone(digest: $0) },
                               approvalKey: { iphone.computerUseApprovalKey(phoneDeviceID: $0) })
        approvals.listen(iphone.computerUseAnswers) { ($0.phoneDeviceID, $0.digest, $0.decision, $0.expiresAt, $0.signature) }
    }
}
