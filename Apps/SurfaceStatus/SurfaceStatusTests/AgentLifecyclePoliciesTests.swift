import Foundation
import Testing
@testable import CMUX_Surface_Status_Sidebar

@Suite("Agent lifecycle safety policies")
struct AgentLifecyclePoliciesTests {
    private let surface = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    @Test func directProcessIdentityRejectsReusedPIDBirth() {
        #expect(DirectStatusProcessIdentity(recordedStartedAt: 1_000).matches(actualStartedAt: 1_000.4))
        #expect(!DirectStatusProcessIdentity(recordedStartedAt: 1_000).matches(actualStartedAt: 1_010))
    }

    @Test func nativeProcessIdentityRequiresExactStoredGeneration() {
        let current = NativeProcessIdentity(seconds: 1_000, microseconds: 123_456)
        #expect(current.matches(recordedSeconds: 1_000, recordedMicroseconds: 123_456))
        #expect(!current.matches(recordedSeconds: 1_000, recordedMicroseconds: 123_457))
        #expect(!current.matches(recordedSeconds: 999, recordedMicroseconds: 123_456))
        #expect(!current.matches(recordedSeconds: 1_000, recordedMicroseconds: 1_000_000))
        #expect(!current.matches(recordedSeconds: nil, recordedMicroseconds: nil))
    }

    @Test func presentClaudeOwnerMapIsExactAndAuthoritative() {
        #expect(LifecycleSessionOwnership.isEligible(
            agentID: "claude",
            sessionID: "owned",
            surfaceID: surface,
            activeSessionsBySurface: [surface.uuidString.lowercased(): "owned"],
            updatedAt: 1_000,
            now: 1_001
        ))
        #expect(!LifecycleSessionOwnership.isEligible(
            agentID: "claude",
            sessionID: "unowned",
            surfaceID: surface,
            activeSessionsBySurface: [surface.uuidString: "owned"],
            updatedAt: 1_000,
            now: 1_001
        ))
        #expect(!LifecycleSessionOwnership.isEligible(
            agentID: "claude",
            sessionID: "session",
            surfaceID: surface,
            activeSessionsBySurface: [:],
            updatedAt: 1_000,
            now: 1_001
        ))
    }

    @Test func absentClaudeOwnerMapAllowsOnlyBriefFallback() {
        #expect(LifecycleSessionOwnership.isEligible(
            agentID: "claude",
            sessionID: "session",
            surfaceID: surface,
            activeSessionsBySurface: nil,
            updatedAt: 995,
            now: 1_000
        ))
        #expect(!LifecycleSessionOwnership.isEligible(
            agentID: "claude",
            sessionID: "session",
            surfaceID: surface,
            activeSessionsBySurface: nil,
            updatedAt: 900,
            now: 1_000
        ))
    }
}
