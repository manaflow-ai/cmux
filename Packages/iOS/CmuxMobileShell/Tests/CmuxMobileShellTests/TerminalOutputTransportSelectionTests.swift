import Testing
@testable import CmuxMobileShell

@Test("a transient status failure retains an already learned verified transport")
func transientStatusFailureRetainsVerifiedTransport() {
    let verifiedCapabilities: Set<String> = [
        "terminal.bytes.v1",
        "terminal.render_grid.v1",
        "terminal.render_grid.verified_replay.v1"
    ]

    #expect(
        fallbackTerminalOutputTransport(learnedCapabilities: verifiedCapabilities) == .renderGrid
    )
    #expect(fallbackTerminalOutputTransport(learnedCapabilities: []) == .rawBytes)
}

@Test("a stale connection cannot restore its learned transport")
func staleConnectionCannotSelectFallbackTransport() {
    let verifiedCapabilities: Set<String> = [
        "terminal.render_grid.v1",
        "terminal.render_grid.verified_replay.v1"
    ]

    #expect(guardedFallbackTerminalOutputTransport(
        learnedCapabilities: verifiedCapabilities,
        isCurrentClient: false
    ) == nil)
    #expect(guardedFallbackTerminalOutputTransport(
        learnedCapabilities: verifiedCapabilities,
        isCurrentClient: true
    ) == .renderGrid)
}
