import CmuxTerminalCore
import Testing

@Suite struct TerminalCommandClickReleaseRouterTests {
    private let router = TerminalCommandClickReleaseRouter()

    @Test func runtimeOpenURLExcludesLocalPathFallback() {
        var pathResolutionAttempted = false

        let route = router.route(
            commandHeld: true,
            pathFallbackSuppressed: false,
            runtimeOutcome: .openURL
        ) {
            pathResolutionAttempted = true
            return .init(path: "/Users/dev/repo", source: .snapshot)
        }

        #expect(route == .runtimeOpenURL)
        #expect(!pathResolutionAttempted)
    }

    @Test func unhandledReleaseUsesResolvedPathFallback() {
        let resolution = TerminalCommandClickReleaseRouter.ResolvedPath(
            path: "/Users/dev/repo/README.md",
            source: .quicklook
        )

        let route = router.route(
            commandHeld: true,
            pathFallbackSuppressed: false,
            runtimeOutcome: .unhandled,
            resolvePath: { resolution }
        )

        #expect(route == .pathFallback(resolution))
    }

    @Test func consumedReleasePreservesPointerSnapshotFallback() {
        let resolution = TerminalCommandClickReleaseRouter.ResolvedPath(
            path: "/Users/dev/repo/README.md",
            source: .snapshot
        )

        let route = router.route(
            commandHeld: true,
            pathFallbackSuppressed: false,
            runtimeOutcome: .consumed,
            resolvePath: { resolution }
        )

        #expect(route == .pathFallback(resolution))
    }

    @Test func consumedQuickLookReleaseDoesNotUsePathFallback() {
        let resolution = TerminalCommandClickReleaseRouter.ResolvedPath(
            path: "/Users/dev/repo/README.md",
            source: .quicklook
        )

        let route = router.route(
            commandHeld: true,
            pathFallbackSuppressed: false,
            runtimeOutcome: .consumed,
            resolvePath: { resolution }
        )

        #expect(route == .none)
    }

    @Test func suppressedPathFallbackDoesNotProbeForPath() {
        var pathResolutionAttempted = false

        let route = router.route(
            commandHeld: true,
            pathFallbackSuppressed: true,
            runtimeOutcome: .unhandled
        ) {
            pathResolutionAttempted = true
            return .init(path: "/Users/dev/repo", source: .snapshot)
        }

        #expect(route == .none)
        #expect(!pathResolutionAttempted)
    }

    @Test func ineligibleReleaseDoesNotProbeForPath() {
        var pathResolutionAttempted = false

        let route = router.route(
            commandHeld: false,
            pathFallbackSuppressed: false,
            runtimeOutcome: .unhandled
        ) {
            pathResolutionAttempted = true
            return .init(path: "/Users/dev/repo", source: .snapshot)
        }

        #expect(route == .none)
        #expect(!pathResolutionAttempted)
    }
}
