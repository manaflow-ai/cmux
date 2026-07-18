import CmuxTerminalBackend
@testable import CmuxTerminalBackendHost
import Foundation
import Testing

@Suite("Backend-only renderer worker transitions")
struct BackendOnlyRendererWorkerTransitionTests {
    private enum RefreshStep: Equatable {
        case retiredIngress
        case configured
    }

    @Test("same-epoch ready is normal readiness, not a restart")
    func sameEpochReadyDoesNotRestart() {
        #expect(BackendOnlyRendererWorkerTransition.action(
            currentRendererEpoch: 7,
            priorRendererEpoch: 7,
            rendererEpoch: 7,
            state: .ready
        ) == .ignore)
    }

    @Test("replacement and unavailable workers restart the presentation")
    func replacementAndUnavailableWorkersRestart() {
        #expect(BackendOnlyRendererWorkerTransition.action(
            currentRendererEpoch: 7,
            priorRendererEpoch: 7,
            rendererEpoch: 8,
            state: .starting
        ) == .restart)
        #expect(BackendOnlyRendererWorkerTransition.action(
            currentRendererEpoch: 7,
            priorRendererEpoch: 7,
            rendererEpoch: 7,
            state: .backoff
        ) == .restart)
        #expect(BackendOnlyRendererWorkerTransition.action(
            currentRendererEpoch: 7,
            priorRendererEpoch: 6,
            rendererEpoch: 7,
            state: .ready
        ) == .ignore)
    }

    @Test("authenticated replacement requires a fresh write-once receiver")
    func replacementWorkerRequiresReceiverRotation() {
        let daemonInstanceID = UUID(
            uuidString: "10000000-0000-0000-0000-000000000001"
        )!
        let currentToken = BackendRendererProcessInstanceToken(
            startTimeSeconds: 10,
            startTimeMicroseconds: 20
        )
        let current = BackendOnlyRendererWorkerIdentity(
            daemonInstanceID: daemonInstanceID,
            rendererEpoch: 7,
            processID: 41,
            effectiveUserID: 501,
            processInstanceToken: currentToken
        )

        #expect(!BackendOnlyRendererWorkerTransition.requiresReceiverRotation(
            currentWorker: current,
            daemonInstanceID: daemonInstanceID,
            rendererEpoch: 7,
            state: .ready,
            processID: 41,
            effectiveUserID: 501,
            processInstanceToken: currentToken
        ))
        #expect(BackendOnlyRendererWorkerTransition.requiresReceiverRotation(
            currentWorker: current,
            daemonInstanceID: daemonInstanceID,
            rendererEpoch: 8,
            state: .ready,
            processID: 42,
            effectiveUserID: 501,
            processInstanceToken: BackendRendererProcessInstanceToken(
                startTimeSeconds: 11,
                startTimeMicroseconds: 21
            )
        ))
        #expect(BackendOnlyRendererWorkerTransition.requiresReceiverRotation(
            currentWorker: current,
            daemonInstanceID: daemonInstanceID,
            rendererEpoch: 7,
            state: .ready,
            processID: 42,
            effectiveUserID: 501,
            processInstanceToken: currentToken
        ))
        #expect(BackendOnlyRendererWorkerTransition.requiresReceiverRotation(
            currentWorker: current,
            daemonInstanceID: daemonInstanceID,
            rendererEpoch: 7,
            state: .backoff,
            processID: nil,
            effectiveUserID: nil,
            processInstanceToken: nil
        ))
        #expect(!BackendOnlyRendererWorkerTransition.requiresReceiverRotation(
            currentWorker: nil,
            daemonInstanceID: daemonInstanceID,
            rendererEpoch: 8,
            state: .starting,
            processID: nil,
            effectiveUserID: nil,
            processInstanceToken: nil
        ))
    }

    @MainActor
    @Test("config refresh retires old ingress before awaiting reconfiguration")
    func configRefreshRetiresIngressFirst() async throws {
        let digest = try BackendRendererConfigDigest(
            validating: String(repeating: "a", count: 64)
        )
        let invalidation = try BackendRendererConfigInvalidated(
            revision: 2,
            digest: digest,
            reason: "default-colors-changed",
            defaultColors: [:]
        )
        var steps: [RefreshStep] = []

        let outcome = try await BackendOnlyRendererConfigRefresh.perform(
            current: nil,
            invalidation: invalidation,
            retireIngress: {
                steps.append(.retiredIngress)
            },
            configure: {
                steps.append(.configured)
                return BackendOnlyRendererConfigIdentity(revision: 2, digest: digest)
            }
        )

        #expect(steps == [.retiredIngress, .configured])
        #expect(outcome == .refreshed(
            BackendOnlyRendererConfigIdentity(revision: 2, digest: digest)
        ))
    }

    @MainActor
    @Test("latest configure receipt coalesces queued config revisions")
    func latestReceiptCoalescesQueuedInvalidations() async throws {
        let secondDigest = try BackendRendererConfigDigest(
            validating: String(repeating: "b", count: 64)
        )
        let thirdDigest = try BackendRendererConfigDigest(
            validating: String(repeating: "c", count: 64)
        )
        let second = try BackendRendererConfigInvalidated(
            revision: 2,
            digest: secondDigest,
            reason: "ghostty-config-reloaded",
            defaultColors: [:]
        )
        let third = try BackendRendererConfigInvalidated(
            revision: 3,
            digest: thirdDigest,
            reason: "ghostty-config-reloaded",
            defaultColors: [:]
        )
        var refreshCount = 0

        let first = try await BackendOnlyRendererConfigRefresh.perform(
            current: BackendOnlyRendererConfigIdentity(
                revision: 1,
                digest: secondDigest
            ),
            invalidation: second,
            retireIngress: {},
            configure: {
                refreshCount += 1
                return BackendOnlyRendererConfigIdentity(
                    revision: 3,
                    digest: thirdDigest
                )
            }
        )
        let current = try #require(first.identity)
        let coalesced = try await BackendOnlyRendererConfigRefresh.perform(
            current: current,
            invalidation: third,
            retireIngress: {
                Issue.record("coalesced invalidation retired ingress again")
            },
            configure: {
                Issue.record("coalesced invalidation configured again")
                return current
            }
        )

        #expect(refreshCount == 1)
        #expect(coalesced == .ignored)
    }

    @MainActor
    @Test("config refresh rejects a receipt older than the invalidation")
    func configRefreshRejectsStaleReceipt() async throws {
        let digest = try BackendRendererConfigDigest(
            validating: String(repeating: "d", count: 64)
        )
        let invalidation = try BackendRendererConfigInvalidated(
            revision: 4,
            digest: digest,
            reason: "ghostty-config-reloaded",
            defaultColors: [:]
        )

        await #expect(throws: BackendOnlyRendererConfigRefreshError.staleReceipt) {
            _ = try await BackendOnlyRendererConfigRefresh.perform(
                current: nil,
                invalidation: invalidation,
                retireIngress: {},
                configure: {
                    BackendOnlyRendererConfigIdentity(revision: 3, digest: digest)
                }
            )
        }
    }
}
