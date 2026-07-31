import Foundation
import Testing
@testable import CMUX_Surface_Status_Sidebar

struct CodexLifecycleProjectionTests {
    private let surfaceA = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    private let surfaceB = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!

    private func session(
        id: String,
        surface: UUID,
        state: SurfaceAgentLifecycle.State? = .running,
        runtime: String? = "running",
        pid: Int32 = 42,
        updatedAt: TimeInterval = 1_000
    ) -> CodexLifecycleSession {
        CodexLifecycleSession(
            sessionID: id,
            agentLifecycle: state,
            runtimeStatus: runtime,
            pid: pid,
            surfaceID: surface.uuidString,
            updatedAt: updatedAt
        )
    }

    @Test func liveLaunchMarkerProjectsImmediateCodexIdleBeforeNativeRecord() {
        let statuses = CodexLifecycleProjection.statuses(
            sessions: [:],
            activeSessionsBySurface: nil,
            launches: [CodexLaunchPresence(surfaceID: surfaceA.uuidString, pid: 42, createdAt: 1_000)],
            now: 1_001,
            processLookup: { _ in CodexProcessSnapshot(startedAt: 999.5) }
        )

        #expect(statuses[surfaceA]?.agentID == "codex")
        #expect(statuses[surfaceA]?.state == .idle)
    }

    @Test func launchMarkerCannotBindToOlderReusedProcess() {
        let statuses = CodexLifecycleProjection.statuses(
            sessions: [:],
            activeSessionsBySurface: nil,
            launches: [CodexLaunchPresence(surfaceID: surfaceA.uuidString, pid: 42, createdAt: 1_000)],
            now: 1_001,
            processLookup: { _ in CodexProcessSnapshot(startedAt: 900) }
        )

        #expect(statuses.isEmpty)
    }

    @Test func deadLaunchMarkerIsIgnored() {
        let statuses = CodexLifecycleProjection.statuses(
            sessions: [:],
            activeSessionsBySurface: nil,
            launches: [CodexLaunchPresence(surfaceID: surfaceA.uuidString, pid: 42, createdAt: 1_000)],
            now: 1_001,
            processLookup: { _ in nil }
        )

        #expect(statuses.isEmpty)
    }

    @Test func nativeLifecycleAlwaysOverridesLaunchMarker() {
        let statuses = CodexLifecycleProjection.statuses(
            sessions: ["session": session(id: "session", surface: surfaceA, runtime: "running", updatedAt: 1_000)],
            activeSessionsBySurface: nil,
            launches: [CodexLaunchPresence(surfaceID: surfaceA.uuidString, pid: 42, createdAt: 1_001)],
            now: 1_002,
            processLookup: { _ in CodexProcessSnapshot(startedAt: 999.5) }
        )

        #expect(statuses[surfaceA]?.state == .running)
    }

    @Test func deadPIDNeverProjectsWorking() {
        let statuses = CodexLifecycleProjection.statuses(
            sessions: ["session": session(id: "session", surface: surfaceA)],
            activeSessionsBySurface: nil,
            now: 1_001,
            processLookup: { _ in nil }
        )

        #expect(statuses[surfaceA] == nil)
    }

    @Test func liveNativeRecordProjectsToItsExactSurface() {
        let statuses = CodexLifecycleProjection.statuses(
            sessions: ["session": session(id: "session", surface: surfaceA)],
            activeSessionsBySurface: nil,
            now: 1_001,
            processLookup: { _ in CodexProcessSnapshot(startedAt: 900) }
        )

        #expect(statuses[surfaceA]?.agentID == "codex")
        #expect(statuses[surfaceA]?.state == .running)
        #expect(statuses[surfaceB] == nil)
    }

    @Test func emptyActiveMapStillAcceptsLiveSurfaceBoundRecord() {
        let statuses = CodexLifecycleProjection.statuses(
            sessions: ["session": session(id: "session", surface: surfaceA, runtime: "idle")],
            activeSessionsBySurface: [:],
            now: 1_001,
            processLookup: { _ in CodexProcessSnapshot(startedAt: 900) }
        )

        #expect(statuses[surfaceA]?.state == .idle)
    }

    @Test func activeOwnershipWinsOverNewerReplacementCandidate() {
        let statuses = CodexLifecycleProjection.statuses(
            sessions: [
                "active": session(id: "active", surface: surfaceA, runtime: "needsInput", updatedAt: 1_000),
                "newer": session(id: "newer", surface: surfaceA, runtime: "running", pid: 43, updatedAt: 1_100),
            ],
            activeSessionsBySurface: [surfaceA.uuidString: "active"],
            now: 1_101,
            processLookup: { _ in CodexProcessSnapshot(startedAt: 900) }
        )

        #expect(statuses[surfaceA]?.state == .needsInput)
        #expect(statuses[surfaceA]?.reason == .interaction)
    }

    @Test func authoritativeDeadOwnerDoesNotReviveOlderLiveSession() {
        let statuses = CodexLifecycleProjection.statuses(
            sessions: [
                "old": session(id: "old", surface: surfaceA, runtime: "running", updatedAt: 1_000),
                "active": session(id: "active", surface: surfaceA, runtime: "running", pid: 43, updatedAt: 1_100),
            ],
            activeSessionsBySurface: [surfaceA.uuidString: "active"],
            now: 1_101,
            processLookup: { pid in
                pid == 42 ? CodexProcessSnapshot(startedAt: 900) : nil
            }
        )

        #expect(statuses[surfaceA] == nil)
    }

    @Test func newestLiveRecordWinsWhenActiveMapIsAbsent() {
        let statuses = CodexLifecycleProjection.statuses(
            sessions: [
                "old": session(id: "old", surface: surfaceA, runtime: "running", updatedAt: 1_000),
                "new": session(id: "new", surface: surfaceA, runtime: "error", pid: 43, updatedAt: 1_100),
            ],
            activeSessionsBySurface: nil,
            now: 1_101,
            processLookup: { _ in CodexProcessSnapshot(startedAt: 900) }
        )

        #expect(statuses[surfaceA]?.state == .needsInput)
        #expect(statuses[surfaceA]?.reason == .error)
    }

    @Test func PIDReuseIsRejectedWhenProcessStartedAfterRecord() {
        let statuses = CodexLifecycleProjection.statuses(
            sessions: ["session": session(id: "session", surface: surfaceA, updatedAt: 1_000)],
            activeSessionsBySurface: nil,
            now: 1_001,
            processLookup: { _ in CodexProcessSnapshot(startedAt: 1_010) }
        )

        #expect(statuses[surfaceA] == nil)
    }

    @Test func PIDReusedImmediatelyAfterRecordIsRejected() {
        let statuses = CodexLifecycleProjection.statuses(
            sessions: ["session": session(id: "session", surface: surfaceA, updatedAt: 1_000)],
            activeSessionsBySurface: nil,
            now: 1_001,
            processLookup: { _ in CodexProcessSnapshot(startedAt: 1_000.001) }
        )

        #expect(statuses[surfaceA] == nil)
    }

    @Test func malformedIdentityAndFutureTimestampFailClosed() {
        let malformed = CodexLifecycleSession(
            sessionID: "different",
            agentLifecycle: .running,
            runtimeStatus: "running",
            pid: 42,
            surfaceID: "not-a-uuid",
            updatedAt: 1_000
        )
        let future = session(id: "future", surface: surfaceB, updatedAt: 2_000)
        let statuses = CodexLifecycleProjection.statuses(
            sessions: ["key": malformed, "future": future],
            activeSessionsBySurface: nil,
            now: 1_000,
            processLookup: { _ in CodexProcessSnapshot(startedAt: 900) }
        )

        #expect(statuses.isEmpty)
    }
}
