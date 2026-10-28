@testable import CmuxMobileShell
import Testing

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct MobileSSHConnectionAttemptTests {
    @Test func disconnectRejectsLateSuccessForOwnerAndJoinedCaller() async throws {
        let harness = SSHConnectionAttemptHarness()
        let gate = SSHConnectionAttemptGate()
        var starts = gate.started.makeAsyncIterator()
        var entries = harness.entered.makeAsyncIterator()
        let owner = Task { try await harness.connection(gate) }
        await starts.next()
        await entries.next()
        let joined = Task { try await harness.connection(gate) }
        await entries.next()

        harness.attempts.cancel(hostID: harness.hostID)
        gate.complete(1)
        await expectSuperseded(owner)
        await expectSuperseded(joined)

        #expect(harness.published.isEmpty)
        #expect(harness.discarded == [1])
        #expect(harness.failures == 0)
        #expect(!harness.attempts.isConnecting(hostID: harness.hostID))
    }

    @Test(arguments: [false, true])
    func lateAttemptPreservesReplacement(fails: Bool) async throws {
        let harness = SSHConnectionAttemptHarness()
        let firstGate = SSHConnectionAttemptGate()
        let replacementGate = SSHConnectionAttemptGate()
        var firstStarts = firstGate.started.makeAsyncIterator()
        var replacementStarts = replacementGate.started.makeAsyncIterator()
        var entries = harness.entered.makeAsyncIterator()
        let first = Task { try await harness.connection(firstGate) }
        await firstStarts.next()
        await entries.next()
        harness.attempts.cancel(hostID: harness.hostID)
        let replacement = Task { try await harness.connection(replacementGate) }
        await replacementStarts.next()
        await entries.next()

        if fails { firstGate.fail() } else { firstGate.complete(1) }
        await expectSuperseded(first)
        let replacementIsRegistered = harness.attempts.isConnecting(hostID: harness.hostID)
        #expect(replacementIsRegistered)
        #expect(harness.published.isEmpty)
        #expect(harness.failures == 0)

        // Let the intentionally broken baseline finish without stranding B.
        guard replacementIsRegistered else {
            replacementGate.complete(2)
            _ = try await replacement.value
            return
        }
        let joined = Task { try await harness.connection(replacementGate) }
        await entries.next()
        replacementGate.complete(2)
        #expect(try await replacement.value == 2)
        #expect(try await joined.value == 2)
        #expect(harness.published == [2])
        #expect(harness.discarded == (fails ? [] : [1]))
        #expect(!harness.attempts.isConnecting(hostID: harness.hostID))
    }

    @Test func joinedCallersSeePublicationBeforeReturning() async throws {
        let harness = SSHConnectionAttemptHarness()
        let gate = SSHConnectionAttemptGate()
        var starts = gate.started.makeAsyncIterator()
        var entries = harness.entered.makeAsyncIterator()
        let owner = Task { try await harness.connection(gate) }
        await starts.next()
        await entries.next()
        let joined = Task {
            let value = try await harness.connection(gate)
            #expect(harness.published == [value])
            return value
        }
        await entries.next()
        gate.complete(7)
        #expect(try await owner.value == 7)
        #expect(try await joined.value == 7)
        #expect(harness.published == [7])
        #expect(harness.discarded.isEmpty)
    }

    @Test func currentFailureIsReportedOnceAndAllowsRetry() async throws {
        let harness = SSHConnectionAttemptHarness()
        let gate = SSHConnectionAttemptGate()
        var starts = gate.started.makeAsyncIterator()
        let owner = Task { try await harness.connection(gate) }
        await starts.next()
        gate.fail()
        do {
            _ = try await owner.value
            Issue.record("Expected the transport failure")
        } catch is SSHConnectionAttemptGate.Failure {
        }
        #expect(harness.failures == 1)
        #expect(!harness.attempts.isConnecting(hostID: harness.hostID))
        let retryGate = SSHConnectionAttemptGate()
        var retryStarts = retryGate.started.makeAsyncIterator()
        let retry = Task { try await harness.connection(retryGate) }
        await retryStarts.next()
        retryGate.complete(9)
        #expect(try await retry.value == 9)
        #expect(harness.published == [9])
    }

    private func expectSuperseded(_ task: Task<Int, any Error>) async {
        do {
            _ = try await task.value
            Issue.record("A disconnected attempt returned a connection")
        } catch is MobileSSHConnectionAttemptSuperseded {
        } catch {
            Issue.record("Expected a superseded attempt, got \(error)")
        }
    }
}
