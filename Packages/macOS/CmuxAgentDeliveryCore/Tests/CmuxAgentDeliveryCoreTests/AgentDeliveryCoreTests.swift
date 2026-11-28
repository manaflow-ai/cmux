import Foundation
import Testing
@testable import CmuxAgentDeliveryCore

@Suite("Agent delivery core")
struct AgentDeliveryCoreTests {
    private let workspaceID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    private let surfaceID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
    private let otherSurfaceID = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!

    /// Corroboration refuses to guess when the two live claims disagree.
    @Test("TTY and process scope disagreement fails closed")
    func disagreementFailsClosed() {
        let tty = AgentDeliveryTargetCandidate(workspaceId: workspaceID, surfaceId: surfaceID)
        let environment = AgentDeliveryTargetCandidate(workspaceId: workspaceID, surfaceId: otherSurfaceID)
        #expect(agentDeliveryTargetCombining(ttyTarget: tty, envTarget: environment) == nil)
    }

    /// A unique PTY match is accepted while duplicate device matches are refused.
    @Test("TTY matching requires one unique live surface")
    func ttyMatchingRequiresUniqueSurface() {
        let unique = agentDeliveryTargetMatchingTTYDevice(
            42,
            surfaceTTYDevices: [(workspaceID, surfaceID, 42)]
        )
        #expect(unique == AgentDeliveryTargetCandidate(workspaceId: workspaceID, surfaceId: surfaceID))

        let ambiguous = agentDeliveryTargetMatchingTTYDevice(
            42,
            surfaceTTYDevices: [
                (workspaceID, surfaceID, 42),
                (workspaceID, otherSurfaceID, 42),
            ]
        )
        #expect(ambiguous == nil)
    }

    /// A start-time change makes otherwise identical PID evidence stale.
    @Test("Process evidence is bound to the current birth-time key")
    func processEvidenceRequiresCurrentKey() {
        let key = CmuxTopProcessScopeCacheKey(pid: 123, startSeconds: 10, startMicroseconds: 20)
        let evidence = AgentDeliveryProcessEvidence(
            isLive: true,
            identityValidated: true,
            ttyDevice: 42,
            scope: nil,
            scopeCacheKey: key
        )
        #expect(agentDeliveryEvidenceMatchesProcess(evidence, currentScopeCacheKey: key))
        #expect(!agentDeliveryEvidenceMatchesProcess(
            evidence,
            currentScopeCacheKey: CmuxTopProcessScopeCacheKey(pid: 123, startSeconds: 11, startMicroseconds: 20)
        ))
    }

    /// The inspector boundary remains independent from the process rules.
    @Test("Process inspector can be injected without AppKit state")
    func inspectorBoundary() {
        let inspector = FixtureInspector()
        let evidence = inspector.inspect(pid: 123, resolution: .controllingTTY)
        #expect(evidence.isLive)
        #expect(evidence.ttyDevice == 42)
    }
}

private struct FixtureInspector: AgentDeliveryProcessInspector {
    /// Supplies deterministic process evidence without touching Darwin state.
    nonisolated func inspect(
        pid: Int32,
        resolution: AgentProcessBindingResolution
    ) -> AgentDeliveryProcessEvidence {
        AgentDeliveryProcessEvidence(
            isLive: pid > 0,
            ttyDevice: 42,
            scope: nil,
            scopeCacheKey: CmuxTopProcessScopeCacheKey(
                pid: Int(pid),
                startSeconds: 10,
                startMicroseconds: 20
            )
        )
    }
}
