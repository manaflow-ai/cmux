import Testing

@testable import CmuxMobileShell

// Behavior tests for the bounded config-theme-mismatch reset budget: a
// genuine one-off theme change still resets (drop the queue, replay with the
// new theme), but a producer alternating between two config themes can no
// longer ping-pong resets and replays forever (the CMUXTERM-MACOS-3CX6 hang
// storm). Past the budget the consumer applies chunks with their own carried
// config theme; a matching chunk re-arms the budget.

@Test func themeMismatchPolicyAllowsAGenuineThemeChangeReset() {
    var policy = TerminalConfigThemeMismatchResetPolicy(maxConsecutiveResets: 3)

    let resets = policy.shouldReset(chunkMatchesStoreTheme: false)

    #expect(resets)
}

@Test func themeMismatchPolicyNeverResetsForMatchingChunks() {
    var policy = TerminalConfigThemeMismatchResetPolicy(maxConsecutiveResets: 3)

    let resets = (0..<10).map { _ in
        policy.shouldReset(chunkMatchesStoreTheme: true)
    }

    #expect(resets.allSatisfy { !$0 })
}

@Test func themeMismatchPolicyBoundsAnAlternatingThemeStorm() {
    var policy = TerminalConfigThemeMismatchResetPolicy(maxConsecutiveResets: 3)

    let mismatches = (0..<103).map { _ in
        policy.shouldReset(chunkMatchesStoreTheme: false)
    }

    // The budget covers the first three mismatches; every further mismatched
    // chunk applies with its own carried theme instead of resetting, however
    // long the storm runs.
    #expect(mismatches.prefix(3).allSatisfy { $0 })
    #expect(mismatches.dropFirst(3).allSatisfy { !$0 })
}

@Test func themeMismatchPolicyReArmsAfterAMatchingChunk() {
    var policy = TerminalConfigThemeMismatchResetPolicy(maxConsecutiveResets: 2)

    let stormResets = (0..<3).map { _ in
        policy.shouldReset(chunkMatchesStoreTheme: false)
    }
    // The world stabilized (a theme-carrying chunk matched the store), so the
    // next genuine theme change is allowed to reset again.
    let matchResets = policy.shouldReset(chunkMatchesStoreTheme: true)
    let reArmedResets = policy.shouldReset(chunkMatchesStoreTheme: false)

    #expect(stormResets == [true, true, false])
    #expect(!matchResets)
    #expect(reArmedResets)
}
