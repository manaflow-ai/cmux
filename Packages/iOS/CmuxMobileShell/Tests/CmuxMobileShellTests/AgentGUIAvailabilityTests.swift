import CmuxAgentReplica
import Testing
@testable import CmuxMobileShell

@Suite struct AgentGUIAvailabilityTests {
    @Test func matchesSelectedTerminalSurface() throws {
        let availability = try #require(AgentGUIAvailability.derive(
            sessions: [
                Self.session(id: "ignored", surfaceID: "other-terminal"),
                Self.session(id: "matched", surfaceID: "terminal-1", kind: .claude),
            ],
            selectedTerminalID: "terminal-1"
        ))

        #expect(availability.sessionID == AgentSessionID(rawValue: "matched"))
        #expect(availability.kind == .claude)
    }

    @Test func newestActivityHintWinsWhenMultipleSessionsMatch() throws {
        let availability = try #require(AgentGUIAvailability.derive(
            sessions: [
                Self.session(id: "older", surfaceID: "terminal-1", lastActivityHint: 20),
                Self.session(id: "newer", surfaceID: "terminal-1", lastActivityHint: 30),
            ],
            selectedTerminalID: "terminal-1"
        ))

        #expect(availability.sessionID == AgentSessionID(rawValue: "newer"))
    }

    @Test func endedSessionDoesNotOfferGUI() {
        let availability = AgentGUIAvailability.derive(
            sessions: [
                Self.session(id: "ended", surfaceID: "terminal-1", phase: .ended),
            ],
            selectedTerminalID: "terminal-1"
        )

        #expect(availability == nil)
    }

    @Test func sessionWithoutSurfaceIsIgnored() {
        let availability = AgentGUIAvailability.derive(
            sessions: [
                Self.session(id: "no-surface", surfaceID: nil),
            ],
            selectedTerminalID: "terminal-1"
        )

        #expect(availability == nil)
    }

    @Test func disconnectedDirectoryProducesNoAvailability() {
        let availability = AgentGUIAvailability.derive(
            sessions: [],
            selectedTerminalID: "terminal-1"
        )

        #expect(availability == nil)
    }

    @Test func missingSelectedTerminalProducesNoAvailability() {
        let availability = AgentGUIAvailability.derive(
            sessions: [
                Self.session(id: "matched", surfaceID: "terminal-1"),
            ],
            selectedTerminalID: nil
        )

        #expect(availability == nil)
    }

    private static func session(
        id: String,
        surfaceID: String?,
        kind: AgentKind = .codex,
        phase: SessionPhase = .working,
        lastActivityHint: Int = 10
    ) -> AgentSessionSnapshot {
        AgentSessionSnapshot(
            id: AgentSessionID(rawValue: id),
            macDeviceID: MacDeviceID(rawValue: "mac-1"),
            kind: kind,
            phase: phase,
            tier: .wrapped,
            surfaceID: surfaceID,
            cwd: "/repo",
            title: id,
            workspaceName: "Workspace",
            version: EntityVersion(rawValue: UInt64(lastActivityHint)),
            lastActivityHint: lastActivityHint
        )
    }
}
