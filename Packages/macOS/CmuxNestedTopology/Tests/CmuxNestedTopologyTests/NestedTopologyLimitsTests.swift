import Testing
@testable import CmuxNestedTopology

@Suite("Nested topology validation limits")
struct NestedTopologyLimitsTests {
    @Test("unknown provider status is retained without being promoted to a known state")
    func retainsUnknownRawStatus() throws {
        let fixture = NestedTopologyTestFixture()
        let status = NestedAgentStatus(
            presentation: .unknown,
            providerRawValue: "waiting-for-review"
        )
        let snapshot = try fixture.snapshot(agents: [fixture.agent(status: status)])

        #expect(snapshot.agents[0].status == status)
        #expect(snapshot.agents[0].status.providerRawValue == "waiting-for-review")
    }

    @Test("empty raw status is invalid even for forward-compatible unknown states")
    func rejectsEmptyStatus() {
        let fixture = NestedTopologyTestFixture()
        let status = NestedAgentStatus(presentation: .unknown, providerRawValue: "")

        #expect(throws: NestedTopologyError.self) {
            try fixture.snapshot(agents: [fixture.agent(status: status)])
        }
    }

    @Test("node counts are bounded per kind and in total")
    func nodeCountLimits() {
        let fixture = NestedTopologyTestFixture()
        let limits = NestedTopologyLimits(
            maximumWorkspaces: 1,
            maximumTabs: 1,
            maximumPanes: 1,
            maximumAgents: 1,
            maximumTotalNodes: 3,
            maximumDepth: 4,
            maximumIdentifierBytes: 64,
            maximumTitleBytes: 64,
            maximumRawStatusBytes: 64,
            maximumSessionIDBytes: 64,
            maximumCapabilities: 8,
            maximumCapabilityBytes: 64
        )

        #expect(throws: NestedTopologyError.self) {
            try fixture.snapshot(limits: limits)
        }

        #expect(throws: NestedTopologyError.self) {
            try fixture.snapshot(
                workspaces: [fixture.workspace("workspace-1"), fixture.workspace("workspace-2")],
                tabs: [],
                panes: [],
                agents: [],
                limits: limits
            )
        }
    }

    @Test("identifier, title, status, session, and capability strings have independent bounds")
    func stringLimits() {
        let fixture = NestedTopologyTestFixture(instanceRawValue: "instance")
        let limits = NestedTopologyLimits(
            maximumWorkspaces: 4,
            maximumTabs: 4,
            maximumPanes: 4,
            maximumAgents: 4,
            maximumTotalNodes: 16,
            maximumDepth: 4,
            maximumIdentifierBytes: 64,
            maximumTitleBytes: 8,
            maximumRawStatusBytes: 8,
            maximumSessionIDBytes: 8,
            maximumCapabilities: 4,
            maximumCapabilityBytes: 8
        )

        #expect(throws: NestedTopologyError.self) {
            try fixture.snapshot(
                capabilities: NestedProviderCapabilities([]),
                workspaces: [fixture.workspace(String(repeating: "i", count: 65))],
                tabs: [],
                panes: [],
                agents: [],
                limits: limits
            )
        }
        #expect(throws: NestedTopologyError.self) {
            try fixture.snapshot(
                capabilities: NestedProviderCapabilities([]),
                workspaces: [fixture.workspace("w", title: NestedNodeTitle(
                    value: "title-too-long",
                    authority: .provider
                ))],
                tabs: [],
                panes: [],
                agents: [],
                limits: limits
            )
        }
        #expect(throws: NestedTopologyError.self) {
            try fixture.snapshot(
                capabilities: NestedProviderCapabilities([]),
                panes: [fixture.pane(sessionID: "s")],
                agents: [fixture.agent(sessionID: "s", status: NestedAgentStatus(
                    presentation: .unknown,
                    providerRawValue: "status-too-long"
                ))],
                limits: limits
            )
        }
        #expect(throws: NestedTopologyError.self) {
            try fixture.snapshot(
                capabilities: NestedProviderCapabilities([]),
                panes: [fixture.pane(sessionID: "session-too-long")],
                limits: limits
            )
        }
        #expect(throws: NestedTopologyError.self) {
            try fixture.snapshot(
                capabilities: NestedProviderCapabilities([
                    NestedProviderCapability(rawValue: "capability-too-long"),
                ]),
                workspaces: [],
                tabs: [],
                panes: [],
                agents: [],
                limits: limits
            )
        }
    }

    @Test("fixed hierarchy depth still honors a stricter consumer limit")
    func depthLimit() {
        let fixture = NestedTopologyTestFixture()
        let limits = NestedTopologyLimits(
            maximumWorkspaces: 8,
            maximumTabs: 8,
            maximumPanes: 8,
            maximumAgents: 8,
            maximumTotalNodes: 32,
            maximumDepth: 3,
            maximumIdentifierBytes: 128,
            maximumTitleBytes: 128,
            maximumRawStatusBytes: 128,
            maximumSessionIDBytes: 128,
            maximumCapabilities: 16,
            maximumCapabilityBytes: 128
        )

        #expect(throws: NestedTopologyError.self) {
            try fixture.snapshot(limits: limits)
        }
        #expect(throws: Never.self) {
            try fixture.snapshot(agents: [], limits: limits)
        }
    }

    @Test("terminal control characters are rejected from display labels")
    func rejectsControlCharacters() {
        let fixture = NestedTopologyTestFixture()

        #expect(throws: NestedTopologyError.self) {
            try fixture.snapshot(workspaces: [fixture.workspace(
                title: NestedNodeTitle(value: "unsafe\u{001B}[31m", authority: .provider)
            )])
        }
    }
}
