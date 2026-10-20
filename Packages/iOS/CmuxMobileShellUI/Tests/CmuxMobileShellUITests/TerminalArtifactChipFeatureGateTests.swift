import SwiftUI
import Testing

@testable import CmuxMobileShellUI

@Suite("Terminal artifact chip feature gate")
struct TerminalArtifactChipFeatureGateTests {
    @Test("shipping environment defaults the terminal Files chip on")
    @MainActor
    func shippingEnvironmentDefaultsOn() {
        #expect(EnvironmentValues().terminalFilesChipEnabled)
    }

    @Test("does not invoke the count scan when the remote feature flag is off")
    @MainActor
    func skipsScanWhenRemoteFlagIsOff() async {
        let gate = TerminalArtifactChipFeatureGate(
            artifactsAvailable: true,
            featureEnabled: false
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

    @Test("runs the count scan only when capability and the remote flag are enabled")
    @MainActor
    func scansWhenFullyEnabled() async {
        let gate = TerminalArtifactChipFeatureGate(
            artifactsAvailable: true,
            featureEnabled: true
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
