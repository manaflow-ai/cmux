@testable import CmuxSudoBroker
import Foundation
import Testing

@Suite("Sudo broker lifecycle regressions")
struct SudoBrokerRegressionTests {
    private let messages = SudoFailureMessages(
        pamTidUnavailable: "pam_tid is not enabled; run scripts/setup-pam-tid.sh",
        approvalTimedOut: "request expired before approval",
        executionInterrupted: "approved execution was interrupted"
    )

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
                recovery: TestExecutionRecovery()
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
        #expect(result.note?.contains("scripts/setup-pam-tid.sh") == true)
        let pending = await broker.pendingRequests()
        #expect(pending.isEmpty)
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
                recovery: TestExecutionRecovery()
            ),
            messages: messages
        )

        let discovered = try await broker.start()

        #expect(discovered.isEmpty)
        let result = try #require(fixture.store.result(id: request.id))
        #expect(result.errorCode == .approvalTimedOut)
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
                recovery: recovery
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
}

