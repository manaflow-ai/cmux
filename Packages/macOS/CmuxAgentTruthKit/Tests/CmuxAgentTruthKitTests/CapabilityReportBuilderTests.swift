import CmuxAgentReplica
@testable import CmuxAgentTruthKit
import Testing

@Suite
struct CapabilityReportBuilderTests {
    @Test
    func reasonsAndBooleansFollowEvidence() {
        let builder = CapabilityReportBuilder()

        var observed = DetectionEvidence(hasProcessObservation: true)
        let observedReport = builder.report(for: observed)
        #expect(observedReport.tier == .observed)
        #expect(observedReport.reasons.contains(.hooksNotObserved))
        #expect(!observedReport.steerable)
        #expect(!observedReport.answerable)

        observed.hasHookEvents = true
        let hooked = builder.report(for: observed)
        #expect(hooked.tier == .hooked)
        #expect(hooked.steerable)
        #expect(hooked.answerable)

        observed.hasWrapperLaunch = true
        let wrapped = builder.report(for: observed)
        #expect(wrapped.tier == .wrapped)
        #expect(wrapped.steerable)

        observed.reasons.insert(.launchedWhileSocketDown)
        observed.reasons.insert(.cliVersionBelowMinimum(found: "0.128", minimum: "0.139"))
        observed.reasons.insert(.transcriptNotReadable)
        observed.reasons.insert(.evidenceConflict)
        observed.reasons.insert(.hooksUnavailableSafeMode)
        let degraded = builder.report(for: observed)
        #expect(degraded.tier == .degraded)
        #expect(degraded.reasons.contains(.launchedWhileSocketDown))
        #expect(degraded.reasons.contains(.cliVersionBelowMinimum(found: "0.128", minimum: "0.139")))
        #expect(degraded.reasons.contains(.transcriptNotReadable))
        #expect(degraded.reasons.contains(.evidenceConflict))
        #expect(degraded.reasons.contains(.hooksUnavailableSafeMode))
        #expect(!degraded.steerable)
        #expect(!degraded.answerable)
    }
}
