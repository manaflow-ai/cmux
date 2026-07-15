import Testing
import CmuxTerminalCore

@Suite struct TerminalCommandClickFallbackPolicyTests {
    private let policy = TerminalCommandClickFallbackPolicy()

    @Test func suppressesFallbackAfterSamePathOpenURLHandling() {
        #expect(
            !policy.shouldOpenFallback(
                ghosttyConsumed: true,
                isSnapshotResolution: true,
                resolvedReference: reference(line: 12, column: 4),
                handledOpenURLReference: reference(line: 12, column: 4)
            )
        )
    }

    @Test func preservesSnapshotFallbackForMismatchedGhosttyTarget() {
        #expect(
            policy.shouldOpenFallback(
                ghosttyConsumed: true,
                isSnapshotResolution: true,
                resolvedReference: reference(path: "/repo/Sources/Wrapped.swift"),
                handledOpenURLReference: reference(path: "/repo/Sources/Other.swift")
            )
        )
    }

    @Test(arguments: [
        (TerminalPathResolution(path: "/repo/Sources/App.swift", line: 37, column: 4),
         TerminalPathResolution(path: "/repo/Sources/App.swift", line: 12, column: 4)),
        (TerminalPathResolution(path: "/repo/Sources/App.swift", line: 12, column: 9),
         TerminalPathResolution(path: "/repo/Sources/App.swift", line: 12, column: 4)),
    ])
    func preservesSnapshotFallbackForDifferentSourceLocation(
        resolvedReference: TerminalPathResolution,
        handledReference: TerminalPathResolution
    ) {
        #expect(
            policy.shouldOpenFallback(
                ghosttyConsumed: true,
                isSnapshotResolution: true,
                resolvedReference: resolvedReference,
                handledOpenURLReference: handledReference
            )
        )
    }

    @Test func consumedNonSnapshotWithoutHandledPathStaysSuppressed() {
        #expect(
            !policy.shouldOpenFallback(
                ghosttyConsumed: true,
                isSnapshotResolution: false,
                resolvedReference: reference(),
                handledOpenURLReference: nil
            )
        )
    }

    @Test func unconsumedResolutionWithoutHandledPathStillOpens() {
        #expect(
            policy.shouldOpenFallback(
                ghosttyConsumed: false,
                isSnapshotResolution: false,
                resolvedReference: reference(),
                handledOpenURLReference: nil
            )
        )
    }

    private func reference(
        path: String = "/repo/Sources/App.swift",
        line: Int? = nil,
        column: Int? = nil
    ) -> TerminalPathResolution {
        TerminalPathResolution(path: path, line: line, column: column)
    }
}
