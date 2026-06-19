import Foundation
import Testing

@testable import CmuxPanes

/// Engine-level edge-trigger + hysteresis behavior, exercised without timers,
/// ghostty, or libproc (the decision core is a pure value type).
@Suite
struct PaneMemoryGuardrailEngineTests {
    private let gb: Int64 = 1024 * 1024 * 1024
    private var threshold: Int64 { 8 * gb }

    private func sample(
        workspace: UUID,
        pane: UUID,
        memoryGB: Double,
        pgids: [Int] = [4242],
        command: String? = "pytest"
    ) -> PaneMemorySample {
        let descriptor = PaneMemoryDescriptor(
            workspaceId: workspace,
            panelId: pane,
            workspaceTitle: "Workspace",
            paneTitle: "Terminal",
            ttyName: "/dev/ttys003",
            foregroundPID: 99
        )
        let bytes = Int64(memoryGB * Double(gb))
        return PaneMemorySample(
            descriptor: descriptor,
            memoryBytes: bytes,
            residentBytes: bytes,
            memoryPressureProcessGroupIDs: pgids,
            foregroundCommand: command
        )
    }

    @Test
    func staysSilentBelowThreshold() {
        var engine = PaneMemoryGuardrailEngine()
        let ws = UUID(), pane = UUID()
        let output = engine.ingest(samples: [sample(workspace: ws, pane: pane, memoryGB: 1)], thresholdBytes: threshold)
        #expect(output.bannerToPresent == nil)
        #expect(output.warnedWorkspaceIds.isEmpty)
    }

    @Test
    func edgeTriggersOnceOnCrossing() {
        var engine = PaneMemoryGuardrailEngine()
        let ws = UUID(), pane = UUID()

        let first = engine.ingest(samples: [sample(workspace: ws, pane: pane, memoryGB: 9)], thresholdBytes: threshold)
        #expect(first.bannerToPresent?.panelId == pane)
        #expect(first.warnedWorkspaceIds == [ws])

        // Still high next tick: no new banner (edge-trigger), badge persists.
        let second = engine.ingest(samples: [sample(workspace: ws, pane: pane, memoryGB: 9)], thresholdBytes: threshold)
        #expect(second.bannerToPresent == nil)
        #expect(second.warnedWorkspaceIds == [ws])
    }

    @Test
    func dismissSuppressesBannerButKeepsBadge() {
        var engine = PaneMemoryGuardrailEngine()
        let ws = UUID(), pane = UUID()
        _ = engine.ingest(samples: [sample(workspace: ws, pane: pane, memoryGB: 9)], thresholdBytes: threshold)

        engine.dismiss(PaneMemoryPaneKey(workspaceId: ws, panelId: pane))
        // Drop into the hysteresis band so the pane re-evaluates without clearing.
        let banded = engine.ingest(samples: [sample(workspace: ws, pane: pane, memoryGB: 7)], thresholdBytes: threshold)
        #expect(banded.bannerToPresent == nil)
        #expect(banded.warnedWorkspaceIds == [ws], "badge persists through the hysteresis band")
    }

    @Test
    func hysteresisClearsBelowClearLevelThenReWarns() {
        var engine = PaneMemoryGuardrailEngine()
        let ws = UUID(), pane = UUID()
        let key = PaneMemoryPaneKey(workspaceId: ws, panelId: pane)

        _ = engine.ingest(samples: [sample(workspace: ws, pane: pane, memoryGB: 9)], thresholdBytes: threshold)
        engine.dismiss(key)

        // 7 GB is in the band (6.4–8): still warned.
        let banded = engine.ingest(samples: [sample(workspace: ws, pane: pane, memoryGB: 7)], thresholdBytes: threshold)
        #expect(banded.warnedWorkspaceIds == [ws])

        // 5 GB is below clear (0.8 × 8 = 6.4): clears and resets dismissal.
        let cleared = engine.ingest(samples: [sample(workspace: ws, pane: pane, memoryGB: 5)], thresholdBytes: threshold)
        #expect(cleared.clearedPanes.contains(key))
        #expect(cleared.warnedWorkspaceIds.isEmpty)

        // Re-crossing fires the banner again.
        let reWarn = engine.ingest(samples: [sample(workspace: ws, pane: pane, memoryGB: 9)], thresholdBytes: threshold)
        #expect(reWarn.bannerToPresent?.panelId == pane)
    }

    @Test
    func closedPaneDropsBadge() {
        var engine = PaneMemoryGuardrailEngine()
        let ws = UUID(), pane = UUID()
        _ = engine.ingest(samples: [sample(workspace: ws, pane: pane, memoryGB: 9)], thresholdBytes: threshold)

        // Pane is gone from the live set: warned state must not linger.
        let output = engine.ingest(samples: [], thresholdBytes: threshold)
        #expect(output.warnedWorkspaceIds.isEmpty)
    }

    @Test
    func singleBannerWithMultipleSimultaneousCrossings() {
        var engine = PaneMemoryGuardrailEngine()
        let wsA = UUID(), paneA = UUID(), wsB = UUID(), paneB = UUID()
        let output = engine.ingest(
            samples: [
                sample(workspace: wsA, pane: paneA, memoryGB: 9),
                sample(workspace: wsB, pane: paneB, memoryGB: 10)
            ],
            thresholdBytes: threshold
        )
        #expect(output.bannerToPresent != nil)
        #expect(output.bannersToPresent.count == 2)
        #expect(output.warnedWorkspaceIds == [wsA, wsB])
    }

    @Test
    func everySimultaneousCrossingIsDeliveredOnce() {
        var engine = PaneMemoryGuardrailEngine()
        let wsA = UUID(), paneA = UUID(), wsB = UUID(), paneB = UUID()
        let first = engine.ingest(
            samples: [
                sample(workspace: wsA, pane: paneA, memoryGB: 9),
                sample(workspace: wsB, pane: paneB, memoryGB: 10)
            ],
            thresholdBytes: threshold
        )
        #expect(Set(first.bannersToPresent.map(\.panelId)) == [paneA, paneB])

        let second = engine.ingest(
            samples: [
                sample(workspace: wsA, pane: paneA, memoryGB: 9),
                sample(workspace: wsB, pane: paneB, memoryGB: 10)
            ],
            thresholdBytes: threshold
        )
        #expect(second.bannersToPresent.isEmpty)
    }
}
