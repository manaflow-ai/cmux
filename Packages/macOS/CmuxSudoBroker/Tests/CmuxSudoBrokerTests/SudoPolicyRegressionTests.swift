@testable import CmuxSudoBroker
import Testing

@Suite("Sudo broker policies")
struct SudoPolicyRegressionTests {
    @Test("PAM parser requires an active sufficient pam_tid rule")
    func pamParser() {
        #expect(!SudoPAMConfiguration.containsEnabledEntry("#auth sufficient pam_tid.so\n"))
        #expect(SudoPAMConfiguration.containsEnabledEntry("auth   sufficient   pam_tid.so\n"))
        #expect(!SudoPAMConfiguration.containsEnabledEntry("auth required pam_tid.so\n"))
    }

    @Test("CLI timeout distinguishes approved execution from pending approval")
    func phaseAwareCLITimeout() {
        #expect(SudoCLITimeoutDisposition.resolve(phase: nil) == .pendingApproval)
        #expect(SudoCLITimeoutDisposition.resolve(phase: .pendingApproval) == .pendingApproval)
        #expect(SudoCLITimeoutDisposition.resolve(phase: .approved) == .approvedExecution)
        #expect(SudoCLITimeoutDisposition.resolve(phase: .executing) == .approvedExecution)
    }
}

