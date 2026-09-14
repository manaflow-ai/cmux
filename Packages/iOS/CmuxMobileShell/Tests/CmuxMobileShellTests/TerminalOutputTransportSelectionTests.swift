import Testing
@testable import CmuxMobileShell

@Test("screen-anchored hosts retain the transport that supports local pixel scrolling")
func screenAnchoredHostKeepsLocalScrollTransport() {
    let capabilities: Set<String> = [
        "terminal.bytes.v1",
        "terminal.render_grid.v1",
        "terminal.render_grid.verified_replay.v1",
        "terminal.render_grid.screen_anchor.v1"
    ]

    #expect(
        MobileShellComposite.resolvedTerminalOutputTransport(
            capabilities: capabilities,
            terminalFidelity: nil
        ) == .renderGrid
    )
    #expect(
        MobileShellComposite.fallbackTerminalOutputTransport(
            learnedCapabilities: capabilities
        ) == .renderGrid
    )
}

@Test("a screen-anchor capability alone cannot select render-grid transport")
func screenAnchorRequiresRenderGridTransport() {
    #expect(
        MobileShellComposite.resolvedTerminalOutputTransport(
            capabilities: ["terminal.bytes.v1", "terminal.render_grid.screen_anchor.v1"],
            terminalFidelity: nil
        ) == .rawBytes
    )
}

@MainActor
@Test("screen-anchored primary scrolling stays local while TUI wheel input still reaches the Mac")
func screenAnchoredHostKeepsPrimaryScrollLocal() async throws {
    let router = LivenessHostRouter()
    await router.setCapabilities([
        "events.v1",
        "terminal.bytes.v1",
        "terminal.render_grid.v1",
        "terminal.render_grid.verified_replay.v1",
        "terminal.render_grid.screen_anchor.v1",
        "terminal.replay.v1"
    ])
    let store = try await makeConnectedStore(
        router: router,
        box: TransportBox(),
        clock: TestClock()
    )
    #expect(store.usesVerifiedTerminalReplay)
    try #require(store.usesScreenAnchoredRenderGrid)
    #expect(!store.ownsLocalPrimaryScreenScroll(surfaceID: "live-terminal"))

    store.terminalActiveScreenBySurfaceID["live-terminal"] = .primary
    #expect(store.ownsLocalPrimaryScreenScroll(surfaceID: "live-terminal"))
    await store.scrollTerminal(surfaceID: "live-terminal", lines: 3, col: 0, row: 0)
    #expect(store.terminalScrollQueuesBySurfaceID["live-terminal"] == nil)
    #expect(await router.count(of: "mobile.terminal.scroll") == 0)

    store.terminalActiveScreenBySurfaceID["live-terminal"] = .alternate
    #expect(!store.ownsLocalPrimaryScreenScroll(surfaceID: "live-terminal"))
    await store.scrollTerminal(surfaceID: "live-terminal", lines: 3, col: 0, row: 0)
    #expect(try await pollUntil { await router.count(of: "mobile.terminal.scroll") == 1 })
}

@Test("a transient status failure retains the dedicated terminal lane")
func transientStatusFailureRetainsVerifiedTransport() {
    let verifiedCapabilities: Set<String> = [
        "terminal.bytes.v1",
        "terminal.render_grid.v1",
        "terminal.render_grid.verified_replay.v1"
    ]

    #expect(
        MobileShellComposite.fallbackTerminalOutputTransport(
            learnedCapabilities: verifiedCapabilities
        ) == .hybrid
    )
    #expect(
        MobileShellComposite.fallbackTerminalOutputTransport(learnedCapabilities: []) == .rawBytes
    )
}

@Test("verified replay does not displace the terminal lane when both are available")
func verifiedReplayKeepsTerminalLanePrimary() {
    let capabilities: Set<String> = [
        "terminal.bytes.v1",
        "terminal.render_grid.v1",
        "terminal.render_grid.verified_replay.v1"
    ]

    #expect(
        MobileShellComposite.resolvedTerminalOutputTransport(
            capabilities: capabilities,
            terminalFidelity: nil
        ) == .hybrid
    )
}

@Test("a stale connection cannot restore its learned transport")
func staleConnectionCannotSelectFallbackTransport() {
    let verifiedCapabilities: Set<String> = [
        "terminal.render_grid.v1",
        "terminal.render_grid.verified_replay.v1"
    ]

    #expect(MobileShellComposite.guardedFallbackTerminalOutputTransport(
        learnedCapabilities: verifiedCapabilities,
        isCurrentClient: false
    ) == nil)
    #expect(MobileShellComposite.guardedFallbackTerminalOutputTransport(
        learnedCapabilities: verifiedCapabilities,
        isCurrentClient: true
    ) == .renderGrid)
}

@Test("verified replay requires the base render-grid capability")
func verifiedReplayRequiresBaseRenderGridCapability() {
    let incompleteCapabilities: Set<String> = [
        "terminal.bytes.v1",
        "terminal.render_grid.verified_replay.v1"
    ]

    #expect(
        MobileShellComposite.resolvedTerminalOutputTransport(
            capabilities: incompleteCapabilities,
            terminalFidelity: nil
        ) == .rawBytes
    )
}
