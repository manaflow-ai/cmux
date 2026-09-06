import Testing
@testable import CmuxMobileShell

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
