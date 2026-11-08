@testable import CmuxNextCloud
import Foundation
import Testing

/// A legacy Cloud link start's steps (``CloudLinkStep``): each answers within its deadline, even when its
/// work never does, and a failure names the step and says whether a retry can help. 2026-11-02: a nightly's
/// Cloud chat start waited 3 minutes with no hub, no link process and no log line.
@Suite struct CloudLinkStartTests {
    @Test func aStepWhoseWorkNeverAnswersFailsAtItsDeadlineNamingTheStep() async {
        let began = ContinuousClock.now
        do {
            _ = try await runLinkStep(.hub, within: .milliseconds(100)) { () async throws -> Int in
                // Work that ignores cancellation (a token read that never returns).
                await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
                return 1
            }
            Issue.record("the step answered")
        } catch let failure as CloudLinkStartError {
            #expect(failure.step == .hub)
            #expect(failure.timedOut)
            #expect(!failure.definitive, "a deadline is not a refusal: the machine may still be booting")
        } catch {
            Issue.record("unexpected \(error)")
        }
        #expect(began.duration(to: .now) < .seconds(5))
    }

    @Test func aStepsOwnErrorKeepsItsStepAndReason() async {
        do {
            _ = try await runLinkStep(.attachEndpoint) { () async throws -> Int in
                throw CloudAPIError.http(status: 403, code: "vm_forbidden", message: "This machine belongs to another team.")
            }
            Issue.record("the step answered")
        } catch let failure as CloudLinkStartError {
            #expect(failure.step == .attachEndpoint)
            #expect(failure.reason == "This machine belongs to another team.")
            #expect(failure.definitive)
            #expect(failure.description.contains("asking cmux Cloud for the machine's address"))
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func onlyARefusalIsDefinitive() {
        let definitive: [any Error] = [
            CloudAPIError.notSignedIn,
            CloudAPIError.http(status: 404, code: nil, message: nil),
            CloudAPIError.planRequired(message: nil, upgradeURL: nil),
            CloudTunnelHub.HubError.revoked,
            ChildProcessError.missingBinary("/x/cmux-tui"),
        ]
        let retryable: [any Error] = [
            CloudAPIError.timedOut("/api/vm/tunnel"),
            CloudAPIError.transport("offline"),
            CloudAPIError.http(status: 409, code: "vm_not_ready", message: nil),
            CloudAPIError.http(status: 429, code: nil, message: nil),
            CloudAPIError.http(status: 503, code: nil, message: nil),
            ChildProcessError.exited(label: "cmux-tui remote connect", stderr: "timed out"),
        ]
        for error in definitive { #expect(CloudLinkStartError(step: .hub, error: error).definitive, "\(error)") }
        for error in retryable { #expect(!CloudLinkStartError(step: .hub, error: error).definitive, "\(error)") }
    }

    @Test func aStartErrorPassesThroughUnchanged() {
        let inner = CloudLinkStartError.deadline(.approve)
        #expect(CloudLinkStartError(step: .remoteConnect, error: inner) == inner)
    }

    @Test func progressKeepsTheRunningStepAndTheLastFailure() {
        let progress = CloudLinkProgress()
        progress.began(.attachEndpoint)
        #expect(progress.snapshot.step == .attachEndpoint)
        progress.failed(.deadline(.hub))
        #expect(progress.snapshot.step == nil)
        #expect(progress.snapshot.failure?.step == .hub)
        progress.began(.attachEndpoint)
        #expect(progress.snapshot.failure?.step == .hub, "a new start keeps the last failure until it comes up")
        progress.succeeded()
        #expect(progress.snapshot == CloudLinkProgress.Snapshot())
    }
}
