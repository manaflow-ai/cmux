#if DEBUG
import Testing
@testable import CmuxMobileShellReleaseGateSupport

struct MobileIrohReleaseGateArtifactPreparationTests {
    @Test
    func completionMarkerCannotAppearInTheEchoedCommand() {
        let preparation = MobileIrohReleaseGateArtifactPreparation.make(
            path: "/tmp/cmux-iroh-gate-test.bin",
            suffixText: "CMUX_IROH_ARTIFACT_TEST",
            marker: "CMUX_IROH_GATE_TEST"
        )

        #expect(preparation.completionMarker.hasPrefix("CMUX_IROH_ARTIFACT_READY_"))
        #expect(!preparation.command.contains(preparation.completionMarker))
    }

    @Test
    func readinessRequiresTwoStableStatObservations() {
        #expect(MobileIrohReleaseGateArtifactPreparation.requiredStableStatObservations == 2)
    }
}
#endif
