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

    @Test("Own workspace + focused surface in a DIFFERENT workspace yields a nil surface, not an impossible pair")
    func partialOwnDoesNotBorrowCrossWorkspaceSurface() {
        // Own workspace present but no own surface; focus is a pane in a different workspace. Stamping
        // (WS-B, A) would be an impossible pair the daemon rejects (dropping the hook), so the surface
        // is left nil for the hook's PID/TTY resolution. The own workspace is still kept.
        let resolved = AgentSpawnIdentity().resolve(
            ownWorkspaceId: "WS-B", ownSurfaceId: nil,
            focusedWorkspaceId: "WS-A", focusedSurfaceId: "A"
        )
        #expect(resolved.workspaceId == "WS-B")
        #expect(resolved.surfaceId == nil)
    }

    @Test("Own workspace + focused surface in the SAME workspace borrows the focused surface")
    func partialOwnBorrowsSameWorkspaceFocusedSurface() {
        // No own surface, but the focused pane is in the resolved workspace, so the pair is coherent.
        let resolved = AgentSpawnIdentity().resolve(
            ownWorkspaceId: "WS-A", ownSurfaceId: nil,
            focusedWorkspaceId: "WS-A", focusedSurfaceId: "A"
        )
        #expect(resolved.workspaceId == "WS-A")
        #expect(resolved.surfaceId == "A")
    }

    @Test("Orphan own surface (no own workspace) is not paired with the focused workspace")
    func orphanOwnSurfaceIsNotPairedWithFocusedWorkspace() {
        // Only CMUX_SURFACE_ID was inherited (no CMUX_WORKSPACE_ID), e.g. partial env scrubbing, while
        // focus is a pane in WS-A. The own surface "B" has an unknown workspace, so stamping (WS-A, B)
        // would be an incoherent cross-workspace pair. The resolver uses the coherent focused pair
        // instead; the orphan own surface is not trusted.
        let resolved = AgentSpawnIdentity().resolve(
            ownWorkspaceId: nil, ownSurfaceId: "B",
            focusedWorkspaceId: "WS-A", focusedSurfaceId: "A"
        )
        #expect(resolved.workspaceId == "WS-A")
        #expect(resolved.surfaceId == "A")
    }

    @Test("Orphan own surface with no focused context yields nil for PID/TTY recovery")
    func orphanOwnSurfaceWithoutFocusYieldsNil() {
        let resolved = AgentSpawnIdentity().resolve(
            ownWorkspaceId: nil, ownSurfaceId: "B",
            focusedWorkspaceId: nil, focusedSurfaceId: nil
        )
        #expect(resolved.workspaceId == nil)
        #expect(resolved.surfaceId == nil)
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
