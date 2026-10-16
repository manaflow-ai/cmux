@testable import CmuxSudoBroker
import Foundation
import Testing

@Suite("Atomic sudo runner recovery", .timeLimit(.minutes(1)))
struct SudoAtomicRunnerRecoveryTests {
    @Test("Cleanup registration cannot replace a claimed runner")
    func claimedRunnerKeepsOwnership() throws {
        let fixture = try SudoTestFixture()
        defer { fixture.remove() }
        let now = Date.now
        let request = try fixture.enqueue(id: "claimed-runner", createdAt: now)
        let pending = try #require(fixture.store.pendingRequests().first)
        _ = try fixture.store.transitionToApproved(
            pending: pending, now: now, executionGraceSeconds: 90
        )
        let identity = TestRunnerLauncher.defaultRunnerIdentity
        let manifest = try fixture.store.claimApprovedExecution(id: request.id, runner: identity, now: now)
        _ = try #require(manifest)
        let claimedState = fixture.store.state(id: request.id)
        let registered = try fixture.store.recordRunnerLaunchFailure(SudoRequestState(
            id: request.id, phase: .executing, updatedAt: now, execution: identity
        ))
        #expect(!registered)
        #expect(fixture.store.state(id: request.id) == claimedState)
    }

    @Test("Cleanup registration blocks a later execution claim")
    func cleanupClaimPreventsExecution() throws {
        let fixture = try SudoTestFixture()
        defer { fixture.remove() }
        let now = Date.now
        let request = try fixture.enqueue(id: "cleanup-owned", createdAt: now)
        let pending = try #require(fixture.store.pendingRequests().first)
        _ = try fixture.store.transitionToApproved(
            pending: pending, now: now, executionGraceSeconds: 90
        )
        let identity = TestRunnerLauncher.defaultRunnerIdentity
        #expect(try fixture.store.recordRunnerLaunchFailure(SudoRequestState(
            id: request.id, phase: .executing, updatedAt: now, execution: identity
        )))
        #expect(try fixture.store.claimApprovedExecution(id: request.id, runner: identity, now: now) == nil)
    }

    @Test("A joined runner finishes partially persisted settlement")
    func joinedRunnerRepairsPartialSettlement() async throws {
        let fixture = try SudoTestFixture()
        defer { fixture.remove() }
        let request = try fixture.enqueue(id: "partial-settlement", createdAt: .now)
        let broker = SudoBroker(
            paths: fixture.paths,
            dependencies: SudoBrokerDependencies(
                clock: TestSudoClock(date: .now),
                pam: TestPAMChecker(enabled: true),
                runner: PartialSettlementRunnerLauncher(paths: fixture.paths),
                recovery: TestExecutionRecovery(),
                watcher: nil,
                requesterInspector: TestSudoProcessInspector()
            ),
            messages: .testMessages
        )
        let events = await broker.events()
        _ = try await broker.start()
        await broker.approve(id: request.id)
        for await event in events {
            if case .snapshot(let pending) = event, pending.isEmpty { break }
        }
        #expect(fixture.store.authoritativeResult(id: request.id)?.errorCode == .runnerLaunchFailed)
        #expect(await broker.pendingRequests().isEmpty)
        await broker.stop()
    }
}
