import Foundation
import Testing

@testable import CmuxWindowing

@Suite struct MultiWindowWindowRouteCoordinatorTests {
    /// Records every argument batch it is asked to route and replays a queued
    /// result per call, so a test can assert the exact CLI flow without
    /// spawning a process.
    private final class RecordingRouter: MultiWindowRouting, @unchecked Sendable {
        // Single-threaded test use; the @unchecked is the test fake's own
        // bookkeeping, not package code.
        private(set) var recordedArguments: [[String]] = []
        private var queuedResults: [MultiWindowRouteResult]

        init(results: [MultiWindowRouteResult]) {
            self.queuedResults = results
        }

        func route(arguments: [String]) async throws -> MultiWindowRouteResult {
            recordedArguments.append(arguments)
            return queuedResults.removeFirst()
        }
    }

    @Test func runsTheThreeCallsInOrderWithTheExactLegacyArguments() async {
        let window1 = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let window2 = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let router = RecordingRouter(results: [
            MultiWindowRouteResult(terminationStatus: 0, stdout: "created", stderr: ""),
            MultiWindowRouteResult(terminationStatus: 0, stdout: "w2-list", stderr: ""),
            MultiWindowRouteResult(terminationStatus: 0, stdout: "w1-list", stderr: ""),
        ])
        let coordinator = MultiWindowWindowRouteCoordinator(router: router)

        let outcome = await coordinator.routeWindowWorkspace(
            title: "route-title",
            window1Id: window1,
            window2Id: window2
        )

        #expect(router.recordedArguments == [
            ["new-workspace", "--window", window2.uuidString, "--name", "route-title", "--focus", "false"],
            ["--json", "--id-format", "uuids", "list-workspaces", "--window", window2.uuidString],
            ["--json", "--id-format", "uuids", "list-workspaces", "--window", window1.uuidString],
        ])
        #expect(outcome.create.stdout == "created")
        #expect(outcome.window2List.stdout == "w2-list")
        #expect(outcome.window1List.stdout == "w1-list")
    }

    @Test func foldsLaunchFailureIntoTheOutcomeWithoutAbortingLaterCalls() async {
        let router = MultiWindowRouter(
            cliURL: URL(fileURLWithPath: "/nonexistent/cmux-cli-\(UUID().uuidString)"),
            socketPath: "/tmp/route.sock",
            environment: [:]
        )
        let coordinator = MultiWindowWindowRouteCoordinator(router: router)

        let outcome = await coordinator.routeWindowWorkspace(
            title: "t",
            window1Id: UUID(),
            window2Id: UUID()
        )

        // Every call should run regardless of launch failure, each folding to
        // the legacy "-1" capture (byte-identical to the pre-extraction code).
        #expect(outcome.create.terminationStatus == -1)
        #expect(outcome.window2List.terminationStatus == -1)
        #expect(outcome.window1List.terminationStatus == -1)
        #expect(!outcome.create.stderr.isEmpty)
    }
}
