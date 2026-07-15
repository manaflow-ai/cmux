import Testing
import CmuxTerminalCore

@Suite struct TerminalCommandClickFallbackPolicyTests {
    private let policy = TerminalCommandClickFallbackPolicy()

    @Test func suppressesFallbackAfterSamePathOpenURLHandling() {
        #expect(
            !policy.shouldOpenFallback(
                ghosttyConsumed: true,
                isSnapshotResolution: true,
                resolvedPath: "/repo/Sources/App.swift",
                handledOpenURLPath: "/repo/Sources/App.swift"
            )
        )
    }

    @Test func preservesSnapshotFallbackForMismatchedGhosttyTarget() {
        #expect(
            policy.shouldOpenFallback(
                ghosttyConsumed: true,
                isSnapshotResolution: true,
                resolvedPath: "/repo/Sources/Wrapped.swift",
                handledOpenURLPath: "/repo/Sources/Other.swift"
            )
        )
    }

    @Test func consumedNonSnapshotWithoutHandledPathStaysSuppressed() {
        #expect(
            !policy.shouldOpenFallback(
                ghosttyConsumed: true,
                isSnapshotResolution: false,
                resolvedPath: "/repo/Sources/App.swift",
                handledOpenURLPath: nil
            )
        )
    }

    @Test func unconsumedResolutionWithoutHandledPathStillOpens() {
        #expect(
            policy.shouldOpenFallback(
                ghosttyConsumed: false,
                isSnapshotResolution: false,
                resolvedPath: "/repo/Sources/App.swift",
                handledOpenURLPath: nil
            )
        )
    }
}
