import CMUXAgentLaunch
import Testing

@Suite("AgentSpawnIdentity")
struct AgentSpawnIdentityTests {
    // The bug: a codex launched in surface B while surface A is focused must keep surface B, not the
    // focused surface A (which would desync from CMUX_PANEL_ID and restore into the wrong surface).
    @Test("Prefers the launcher's own surface over the focused pane")
    func prefersOwnOverFocused() {
        let resolved = AgentSpawnIdentity().resolve(
            ownWorkspaceId: "WS-B", ownSurfaceId: "B",
            focusedWorkspaceId: "WS-A", focusedSurfaceId: "A"
        )
        #expect(resolved.workspaceId == "WS-B")
        #expect(resolved.surfaceId == "B")
    }

    @Test("Falls back to the focused pane only when the launcher has no own identity")
    func fallsBackToFocusedWhenNoOwn() {
        let resolved = AgentSpawnIdentity().resolve(
            ownWorkspaceId: nil, ownSurfaceId: nil,
            focusedWorkspaceId: "WS-A", focusedSurfaceId: "A"
        )
        #expect(resolved.workspaceId == "WS-A")
        #expect(resolved.surfaceId == "A")
    }

    @Test("Blank own identity is treated as absent")
    func blankOwnIsAbsent() {
        let resolved = AgentSpawnIdentity().resolve(
            ownWorkspaceId: "   ", ownSurfaceId: "",
            focusedWorkspaceId: "WS-A", focusedSurfaceId: "A"
        )
        #expect(resolved.workspaceId == "WS-A")
        #expect(resolved.surfaceId == "A")
    }

    @Test("Per-element independence: own workspace + focused-only surface")
    func perElementIndependence() {
        // Own workspace present but no own surface, focused has both: workspace from own, surface from focused.
        let resolved = AgentSpawnIdentity().resolve(
            ownWorkspaceId: "WS-B", ownSurfaceId: nil,
            focusedWorkspaceId: "WS-A", focusedSurfaceId: "A"
        )
        #expect(resolved.workspaceId == "WS-B")
        #expect(resolved.surfaceId == "A")
    }

    @Test("No identity anywhere yields nil")
    func noIdentity() {
        let resolved = AgentSpawnIdentity().resolve(
            ownWorkspaceId: nil, ownSurfaceId: nil,
            focusedWorkspaceId: nil, focusedSurfaceId: nil
        )
        #expect(resolved.workspaceId == nil)
        #expect(resolved.surfaceId == nil)
    }
}
