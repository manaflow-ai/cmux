@testable import CmuxSudoBroker
import Foundation
import Testing

@Suite("Sudo broker lifecycle regressions")
struct SudoBrokerRegressionTests {
    private let messages = SudoFailureMessages.testMessages

    @Test("Missing pam_tid settles without launching sudo")
    func missingPAMFailsBeforeLaunch() async throws {
        let fixture = try SudoTestFixture()
        defer { fixture.remove() }
        let now = Date(timeIntervalSince1970: 1_786_000_000)
        let request = try fixture.enqueue(id: "missing-pam", createdAt: now)
        let launcher = TestRunnerLauncher()
        let broker = SudoBroker(
            paths: fixture.paths,
            dependencies: SudoBrokerDependencies(
                clock: TestSudoClock(date: now),
                pam: TestPAMChecker(enabled: false),
                runner: launcher,
                recovery: TestExecutionRecovery(),
                watcher: nil,
                requesterInspector: TestSudoProcessInspector()
            ),
            messages: messages
        )

        _ = try await broker.start()
        await broker.approve(id: request.id)

        let launchedRequestIDs = await launcher.launchedRequestIDs
        #expect(launchedRequestIDs.isEmpty)
        let result = try #require(fixture.store.result(id: request.id))
        #expect(result.status == .failed)
        #expect(result.errorCode == .pamTidUnavailable)
        #expect(result.note == messages.pamTidUnavailable)
        let pending = await broker.pendingRequests()
        #expect(pending.isEmpty)
    }

    @Test("Approval hands the exact reviewed bytes to the detached runner")
    func approvalLaunchesReviewedScriptCapability() async throws {
        let fixture = try SudoTestFixture()
        defer { fixture.remove() }
        let now = Date(timeIntervalSince1970: 1_786_000_000)
        let request = try fixture.enqueue(id: "reviewed-capability", createdAt: now)
        let reviewedScript = Data("echo test\n".utf8)
        let launcher = TestRunnerLauncher()
        let broker = SudoBroker(
            paths: fixture.paths,
            dependencies: SudoBrokerDependencies(
                clock: TestSudoClock(date: now),
                pam: TestPAMChecker(enabled: true),
                runner: launcher,
                recovery: TestExecutionRecovery(),
                watcher: nil,
                requesterInspector: TestSudoProcessInspector()
            ),
            messages: messages
        )

        _ = try await broker.start()
        try Data("echo replaced after review\n".utf8).write(
            to: fixture.paths.requests.appendingPathComponent("\(request.id).sh")
        )
        await broker.approve(id: request.id)

        #expect(await launcher.reviewedScripts[request.id] == reviewedScript)
    }

    @Test("Refresh never recovers an execution owned by this broker")
    func refreshDoesNotRecoverKnownApproval() async throws {
        let fixture = try SudoTestFixture()
        defer { fixture.remove() }
        let now = Date(timeIntervalSince1970: 1_786_000_000)
        let request = try fixture.enqueue(id: "broker-owned", createdAt: now)
        let recovery = TestExecutionRecovery()
        let broker = SudoBroker(
            paths: fixture.paths,
            dependencies: SudoBrokerDependencies(
                clock: TestSudoClock(date: now),
                pam: TestPAMChecker(enabled: true),
                runner: TestRunnerLauncher(),
                recovery: recovery,
                watcher: nil,
                requesterInspector: TestSudoProcessInspector()
            ),
            messages: messages
        )

        _ = try await broker.start()
        await broker.approve(id: request.id)
        _ = try await broker.refresh()

        let recoveredRequestIDs = await recovery.recoveryBatches
            .flatMap { $0.map(\.id) }
        #expect(!recoveredRequestIDs.contains(request.id))
        #expect(fixture.store.result(id: request.id) == nil)
    }

    @Test("A launched runner that exits early is recovered and settled", .timeLimit(.minutes(1)))
    func runnerTerminationSettlesApprovedRequest() async throws {
        let fixture = try SudoTestFixture()
        defer { fixture.remove() }
        let now = Date(timeIntervalSince1970: 1_786_000_000)
        let request = try fixture.enqueue(id: "runner-exited", createdAt: now)
        let launcher = TestRunnerLauncher()
        let recovery = TestExecutionRecovery()
        let broker = SudoBroker(
            paths: fixture.paths,
            dependencies: SudoBrokerDependencies(
                clock: TestSudoClock(date: now),
                pam: TestPAMChecker(enabled: true),
                runner: launcher,
                recovery: recovery,
                watcher: nil,
                requesterInspector: TestSudoProcessInspector()
            ),
            messages: messages
        )
        let events = await broker.events()

        _ = try await broker.start()
        await broker.approve(id: request.id)
        await launcher.terminate(requestID: request.id)

        var iterator = events.makeAsyncIterator()
        var requestWasRemoved = false
        while let event = await iterator.next() {
            guard case .snapshot(let snapshots) = event,
                  !snapshots.contains(where: { $0.request.id == request.id }) else {
                continue
            }
            requestWasRemoved = true
            break
        }

        #expect(requestWasRemoved)
        #expect(fixture.store.result(id: request.id)?.errorCode == .executionInterrupted)
        let recoveredStates = await recovery.recoveredStates
        #expect(recoveredStates.count == 1)
        #expect(recoveredStates.first?.phase == .approved)
    }

    @Test("Startup expires old approvals instead of rediscovering them")
    func startupExpiresPendingRequests() async throws {
        let fixture = try SudoTestFixture()
        defer { fixture.remove() }
        let now = Date(timeIntervalSince1970: 1_786_000_000)
        let request = try fixture.enqueue(
            id: "expired",
            createdAt: now.addingTimeInterval(-31),
            timeoutSeconds: 30
        )
        let broker = SudoBroker(
            paths: fixture.paths,
            dependencies: SudoBrokerDependencies(
                clock: TestSudoClock(date: now),
                pam: TestPAMChecker(enabled: true),
                runner: TestRunnerLauncher(),
                recovery: TestExecutionRecovery(),
                watcher: nil,
                requesterInspector: TestSudoProcessInspector()
            ),
            messages: messages
        )

        let discovered = try await broker.start()

        #expect(discovered.isEmpty)
        let result = try #require(fixture.store.result(id: request.id))
        #expect(result.errorCode == .approvalTimedOut)
    }

    @Test(
        "Restart returns known pending approvals and restores their deadline",
        .timeLimit(.minutes(1))
    )
    func restartReconcilesKnownPendingRequests() async throws {
        let fixture = try SudoTestFixture()
        defer { fixture.remove() }
        let now = Date(timeIntervalSince1970: 1_786_000_000)
        let request = try fixture.enqueue(id: "restart-pending", createdAt: now)
        let clock = TestSudoClock(date: now)
        let broker = SudoBroker(
            paths: fixture.paths,
            dependencies: SudoBrokerDependencies(
                clock: clock,
                pam: TestPAMChecker(enabled: true),
                runner: TestRunnerLauncher(),
                recovery: TestExecutionRecovery(),
                watcher: nil,
                requesterInspector: TestSudoProcessInspector()
            ),
            messages: messages
        )

        let initiallyActive = try await broker.start()
        #expect(initiallyActive.map(\.request.id) == [request.id])
        await broker.stop()

        let activeAfterRestart = try await broker.start()
        try #require(activeAfterRestart.map(\.request.id) == [request.id])

        var events = await broker.events().makeAsyncIterator()
        await clock.advance(to: request.approvalDeadline)
        var requestWasRemoved = false
        while let event = await events.next() {
            guard case .snapshot(let snapshots) = event,
                  !snapshots.contains(where: { $0.request.id == request.id }) else {
                continue
            }
            requestWasRemoved = true
            break
        }

        #expect(requestWasRemoved)
        #expect(fixture.store.result(id: request.id)?.errorCode == .approvalTimedOut)
        await broker.stop()
    }

    @Test("Startup rejects a request whose PID generation has exited")
    func startupRejectsUnavailableRequester() async throws {
        let fixture = try SudoTestFixture()
        defer { fixture.remove() }
        let now = Date(timeIntervalSince1970: 1_786_000_000)
        let identity = SudoProcessIdentity(
            processIdentifier: 123,
            startSeconds: 10,
            startMicroseconds: 20
        )
        let request = try fixture.enqueue(
            id: "requester-exited",
            createdAt: now,
            requesterIdentity: identity
        )
        let inspector = TestRunnerBootstrapInspector(
            parentProcessIdentifier: identity.processIdentifier,
            parentExecutableURL: URL(fileURLWithPath: "/usr/bin/test-agent")
        )
        let broker = SudoBroker(
            paths: fixture.paths,
            dependencies: SudoBrokerDependencies(
                clock: TestSudoClock(date: now),
                pam: TestPAMChecker(enabled: true),
                runner: TestRunnerLauncher(),
                recovery: TestExecutionRecovery(),
                watcher: nil,
                requesterInspector: inspector
            ),
            messages: messages
        )

        let discovered = try await broker.start()

        #expect(discovered.isEmpty)
        #expect(fixture.store.result(id: request.id)?.errorCode == .requesterUnavailable)
    }

    @Test(
        "Requester exit settles a pending request without waiting for its deadline",
        .timeLimit(.minutes(1))
    )
    func requesterExitSettlesPendingRequest() async throws {
        let fixture = try SudoTestFixture()
        defer { fixture.remove() }
        let now = Date(timeIntervalSince1970: 1_786_000_000)
        let request = try fixture.enqueue(
            id: "requester-exit",
            createdAt: now,
            timeoutSeconds: 3_600
        )
        let broker = SudoBroker(
            paths: fixture.paths,
            dependencies: SudoBrokerDependencies(
                clock: TestSudoClock(date: now),
                pam: TestPAMChecker(enabled: true),
                runner: TestRunnerLauncher(),
                recovery: TestExecutionRecovery(),
                watcher: nil,
                requesterInspector: TestSudoProcessInspector(),
                requesterExitObserver: ImmediateRequesterExitObserver()
            ),
            messages: messages
        )

        let eventStream = await broker.events()
        var events = eventStream.makeAsyncIterator()
        _ = try await broker.start()
        while let event = await events.next() {
            guard case .snapshot(let snapshots) = event else { continue }
            if snapshots.isEmpty { break }
        }

        #expect(fixture.store.result(id: request.id)?.errorCode == .requesterUnavailable)
        #expect(await broker.pendingRequests().isEmpty)
        await broker.stop()
    }

    @Test("Startup rejects legacy requests without a generation-qualified requester")
    func startupRejectsMissingRequesterIdentity() async throws {
        let fixture = try SudoTestFixture()
        defer { fixture.remove() }
        let now = Date(timeIntervalSince1970: 1_786_000_000)
        let request = try fixture.enqueueLegacy(id: "requester-missing", createdAt: now)
        let broker = SudoBroker(
            paths: fixture.paths,
            dependencies: SudoBrokerDependencies(
                clock: TestSudoClock(date: now),
                pam: TestPAMChecker(enabled: true),
                runner: TestRunnerLauncher(),
                recovery: TestExecutionRecovery(),
                watcher: nil,
                requesterInspector: TestSudoProcessInspector()
            ),
            messages: messages
        )

        let discovered = try await broker.start()

        #expect(discovered.isEmpty)
        #expect(fixture.store.result(id: request.id)?.errorCode == .requesterUnavailable)
    }

    @Test("Startup reaps and settles interrupted approved execution")
    func startupRecoversInterruptedExecution() async throws {
        let fixture = try SudoTestFixture()
        defer { fixture.remove() }
        let now = Date(timeIntervalSince1970: 1_786_000_000)
        let request = try fixture.enqueue(id: "interrupted", createdAt: now)
        let state = SudoRequestState(
            id: request.id,
            phase: .executing,
            updatedAt: now,
            runner: SudoProcessIdentity(
                processIdentifier: 5_150,
                startSeconds: 100,
                startMicroseconds: 200
            ),
            execution: SudoProcessIdentity(
                processIdentifier: 5_151,
                startSeconds: 101,
                startMicroseconds: 201
            )
        )
        try fixture.store.writeState(state)
        let recovery = TestExecutionRecovery()
        let broker = SudoBroker(
            paths: fixture.paths,
            dependencies: SudoBrokerDependencies(
                clock: TestSudoClock(date: now),
                pam: TestPAMChecker(enabled: true),
                runner: TestRunnerLauncher(),
                recovery: recovery,
                watcher: nil,
                requesterInspector: TestSudoProcessInspector()
            ),
            messages: messages
        )

        let discovered = try await broker.start()

        #expect(discovered.isEmpty)
        let recoveredStates = await recovery.recoveredStates
        #expect(recoveredStates == [state])
        let result = try #require(fixture.store.result(id: request.id))
        #expect(result.errorCode == .executionInterrupted)
    }

    @Test("Startup batches recovery and continues after one settlement fails")
    func startupRecoveryIsBatchedAndFailureIsolated() async throws {
        let fixture = try SudoTestFixture()
        defer { fixture.remove() }
        let now = Date(timeIntervalSince1970: 1_786_000_000)
        let first = try fixture.enqueue(id: "a-settle-fails", createdAt: now)
        let second = try fixture.enqueue(id: "b-settles", createdAt: now)
        let states = [first, second].map { request in
            SudoRequestState(
                id: request.id,
                phase: .executing,
                updatedAt: now,
                execution: SudoProcessIdentity(
                    processIdentifier: request.id == first.id ? 5_160 : 5_161,
                    startSeconds: 110,
                    startMicroseconds: 210
                )
            )
        }
        for state in states {
            try fixture.store.writeState(state)
        }
        try Data().write(
            to: fixture.paths.results.appendingPathComponent("\(first.id).json")
        )
        let recovery = TestExecutionRecovery()
        let broker = SudoBroker(
            paths: fixture.paths,
            dependencies: SudoBrokerDependencies(
                clock: TestSudoClock(date: now),
                pam: TestPAMChecker(enabled: true),
                runner: TestRunnerLauncher(),
                recovery: recovery,
                watcher: nil,
                requesterInspector: TestSudoProcessInspector()
            ),
            messages: messages
        )

        _ = try await broker.start()

        #expect(await recovery.recoveryBatches == [states])
        #expect(fixture.store.result(id: first.id) == nil)
        #expect(fixture.store.result(id: second.id)?.errorCode == .executionInterrupted)
    }

    @Test("Incomplete cleanup settles while retaining restart recovery evidence")
    func incompleteCleanupRemainsRecoverable() async throws {
        let fixture = try SudoTestFixture()
        defer { fixture.remove() }
        let now = Date(timeIntervalSince1970: 1_786_000_000)
        let request = try fixture.enqueue(id: "cleanup-incomplete", createdAt: now)
        let pending = try #require(
            fixture.store.pendingRequests().first { $0.request.id == request.id }
        )
        _ = try fixture.store.transitionToApproved(
            pending: pending,
            now: now,
            executionGraceSeconds: 90
        )
        let state = SudoRequestState(
            id: request.id,
            phase: .executing,
            updatedAt: now,
            execution: SudoProcessIdentity(
                processIdentifier: 5_152,
                startSeconds: 102,
                startMicroseconds: 202
            )
        )
        try fixture.store.writeState(state)
        let recovery = TestExecutionRecovery(disposition: .cleanupIncomplete)
        let broker = SudoBroker(
            paths: fixture.paths,
            dependencies: SudoBrokerDependencies(
                clock: TestSudoClock(date: now),
                pam: TestPAMChecker(enabled: true),
                runner: TestRunnerLauncher(),
                recovery: recovery,
                watcher: nil,
                requesterInspector: TestSudoProcessInspector()
            ),
            messages: messages
        )

        let discovered = try await broker.start()

        #expect(discovered.isEmpty)
        let result = try #require(fixture.store.result(id: request.id))
        #expect(result.errorCode == .processCleanupFailed)
        #expect(fixture.store.state(id: request.id) == state)
        #expect(FileManager.default.fileExists(atPath: fixture.store.approvedScriptURL(id: request.id).path))
        #expect(fixture.store.manifest(id: request.id) != nil)
    }

    @Test("Startup retries and archives a recovered cleanup failure")
    func startupRetriesTerminalCleanupFailure() async throws {
        let fixture = try SudoTestFixture()
        defer { fixture.remove() }
        let now = Date(timeIntervalSince1970: 1_786_000_000)
        let request = try fixture.enqueue(id: "cleanup-recovered", createdAt: now)
        let pending = try #require(
            fixture.store.pendingRequests().first { $0.request.id == request.id }
        )
        _ = try fixture.store.transitionToApproved(
            pending: pending,
            now: now,
            executionGraceSeconds: 90
        )
        let survivor = SudoProcessIdentity(
            processIdentifier: 5_153,
            startSeconds: 103,
            startMicroseconds: 203
        )
        let state = SudoRequestState(
            id: request.id,
            phase: .executing,
            updatedAt: now,
            execution: survivor,
            cleanupSurvivors: [survivor]
        )
        try fixture.store.writeState(state)
        _ = try fixture.store.settle(
            SudoResult(
                id: request.id,
                status: .failed,
                errorCode: .processCleanupFailed,
                note: messages.cleanupFailed
            )
        )
        let recovery = TestExecutionRecovery(disposition: .recovered)
        let broker = SudoBroker(
            paths: fixture.paths,
            dependencies: SudoBrokerDependencies(
                clock: TestSudoClock(date: now),
                pam: TestPAMChecker(enabled: true),
                runner: TestRunnerLauncher(),
                recovery: recovery,
                watcher: nil,
                requesterInspector: TestSudoProcessInspector()
            ),
            messages: messages
        )

        _ = try await broker.start()

        #expect(await recovery.recoveredStates == [state])
        #expect(fixture.store.state(id: request.id) == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.store.approvedScriptURL(id: request.id).path))
        #expect(fixture.store.manifest(id: request.id) == nil)
        #expect(fixture.store.result(id: request.id)?.errorCode == .processCleanupFailed)
    }
}

private struct ImmediateRequesterExitObserver: SudoProcessExitObserving {
    func events(for identity: SudoProcessIdentity) -> AsyncStream<Void> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            continuation.yield(())
            continuation.finish()
        }
    }
}
