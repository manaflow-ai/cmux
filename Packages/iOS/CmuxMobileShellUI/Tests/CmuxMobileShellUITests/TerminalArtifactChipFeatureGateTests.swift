import Testing

@testable import CmuxMobileShellUI

@Suite("Terminal artifact chip feature gate")
struct TerminalArtifactChipFeatureGateTests {
    @Test("does not invoke the count scan when the preference is off")
    @MainActor
    func skipsScanWhenPreferenceIsOff() async {
        let gate = TerminalArtifactChipFeatureGate(
            artifactsAvailable: true,
            preferenceEnabled: false
        )
        var scanInvocationCount = 0

        let result: Int? = await gate.performScan {
            scanInvocationCount += 1
            return 7
        }

        #expect(!gate.isEnabled)
        #expect(scanInvocationCount == 0)
        #expect(result == nil)
    }

    @Test("runs the count scan only when capability and preference are enabled")
    @MainActor
    func scansWhenFullyEnabled() async {
        let gate = TerminalArtifactChipFeatureGate(
            artifactsAvailable: true,
            preferenceEnabled: true
        )
        var scanInvocationCount = 0

        let result: Int? = await gate.performScan {
            scanInvocationCount += 1
            return 7
        }

        #expect(gate.isEnabled)
        #expect(scanInvocationCount == 1)
        #expect(result == 7)
    }
}
