@testable import CmuxSudoBroker
import Darwin
import Foundation
import Testing

@Suite("Sudo registration failures", .timeLimit(.minutes(1)))
struct SudoRegistrationFailureTests {
    @Test("Cancelled startup stops the watcher before another start")
    func cancelledStartupStopsWatcher() async throws {
        let fixture = try SudoTestFixture()
        defer { fixture.remove() }
        let watcher = SuspendedSudoWatcher()
        let broker = makeBroker(paths: fixture.paths, watcher: watcher)
        let starting = Task { try await broker.start() }
        await watcher.waitUntilStarted()
        starting.cancel()
        await watcher.releaseStart()
        await #expect(throws: CancellationError.self) { try await starting.value }
        #expect(await watcher.activeWatches == 0)
        _ = try await broker.start()
        #expect(await watcher.activeWatches == 1)
        await broker.stop()
        #expect(await watcher.activeWatches == 0)
    }

    @Test("Rejected execution registration produces a durable result", arguments: [false, true])
    func rejectedExecutionRegistrationSettles(preserveResult: Bool) throws {
        let fixture = try SudoTestFixture()
        defer { fixture.remove() }
        let now = Date.now
        let request = try fixture.enqueue(id: "execution-registration", createdAt: now)
        let pending = try #require(fixture.store.pendingRequests().first)
        _ = try fixture.store.transitionToApproved(
            pending: pending, now: now, executionGraceSeconds: 90
        )
        let parentURL = URL(fileURLWithPath: "/Applications/cmux.app/Contents/MacOS/cmux")
        let inspector = TestRunnerBootstrapInspector(
            parentProcessIdentifier: 2_000_000_000,
            parentExecutableURL: parentURL,
            runnerProcessIdentifier: getpid()
        )
        let capability = SudoReviewedScriptCapability(
            bytes: Data(pending.script.utf8), temporaryDirectoryURL: fixture.root
        )
        try capability.withDescriptor { descriptor in
            let runner = SudoExecutionRunner(
                store: fixture.store,
                pam: TestPAMChecker(enabled: true),
                inspector: inspector,
                parentValidator: SudoRunnerParentValidator(
                    inspector: inspector, parentProcessIdentifier: { 2_000_000_000 }
                ),
                processRunner: SudoBoundedProcessRunner(
                    spawner: RegistrationFailureSpawner(
                        paths: fixture.paths, requestID: request.id, preserveResult: preserveResult
                    ),
                    inspector: inspector,
                    signaler: TestSudoProcessSignaler()
                ),
                reviewedScriptReader: SudoReviewedScriptReader(descriptor: descriptor),
                expectedParentExecutableURL: parentURL,
                messages: .testMessages,
                now: { now }
            )
            _ = runner.run(requestID: request.id)
        }
        let result = try #require(fixture.store.authoritativeResult(id: request.id))
        if preserveResult {
            #expect(result.status == .denied)
        } else {
            #expect(result.status == .failed)
            #expect(result.errorCode == .runnerLaunchFailed)
        }
        #expect(fixture.store.state(id: request.id) == nil)
    }

    @Test("An unavailable registration store does not authorize killing the runner")
    func runnerRegistrationFailureKeepsMonitor() async throws {
        let fixture = try SudoTestFixture()
        defer { fixture.remove() }
        let launcher = RegistrationFailureLauncher(paths: fixture.paths)
        let recovery = TestExecutionRecovery()
        let broker = makeBroker(paths: fixture.paths, runner: launcher, recovery: recovery)
        let request = try fixture.enqueue(id: "runner-registration", createdAt: .now)
        let events = await broker.events()
        _ = try await broker.start()
        await broker.approve(id: request.id)
        #expect(await recovery.recoveredStates.isEmpty)
        #expect(fixture.store.result(id: request.id) == nil)
        try await launcher.allowRegistration(requestID: request.id)
        #expect(try fixture.store.claimApprovedExecution(
            id: request.id, runner: TestRunnerLauncher.defaultRunnerIdentity, now: .now
        ) != nil)
        let completed = SudoResult(id: request.id, status: .completed, exitCode: 0)
        _ = try fixture.store.settle(completed)
        await launcher.finish()
        for await event in events {
            if case .snapshot(let pending) = event, pending.isEmpty { break }
        }
        #expect(fixture.store.authoritativeResult(id: request.id) == completed)
        #expect(await broker.pendingRequests().isEmpty)
        await broker.stop()
    }

    private func makeBroker(
        paths: SudoBrokerPaths,
        watcher: (any SudoSpoolWatching)? = nil,
        runner: any SudoRunnerLaunching = TestRunnerLauncher(),
        recovery: any SudoInterruptedExecutionRecovering = TestExecutionRecovery()
    ) -> SudoBroker {
        SudoBroker(
            paths: paths,
            dependencies: SudoBrokerDependencies(
                clock: TestSudoClock(date: .now),
                pam: TestPAMChecker(enabled: true),
                runner: runner,
                recovery: recovery,
                watcher: watcher,
                requesterInspector: TestSudoProcessInspector()
            ),
            messages: .testMessages
        )
    }
}
