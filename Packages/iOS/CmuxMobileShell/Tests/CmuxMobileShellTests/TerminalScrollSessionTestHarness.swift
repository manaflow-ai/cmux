import CMUXMobileCore
import Foundation
@testable import CmuxMobileShell

@MainActor
final class TerminalScrollSessionHarness {
    struct PendingLocal {
        let continuation: LocalReceiptContinuation
    }

    @MainActor
    final class LocalReceiptContinuation {
        let receipt: TerminalSurfaceMutationReceipt

        init(receipt: TerminalSurfaceMutationReceipt) {
            self.receipt = receipt
        }

        func resume(returning applied: Bool) {
            receipt.resolve(applied)
        }
    }

    struct LocalStarted {
        let lines: Double
        let primaryRows: Int?
        let col: Int
        let row: Int
    }

    struct PendingRemote {
        let request: TerminalScrollRequest
        let continuation: CheckedContinuation<TerminalScrollResponse?, Never>
    }

    final class LocalLane {
        var started: [LocalStarted] = []
        var pending: [PendingLocal] = []
    }

    final class RemoteLane {
        var started: [TerminalScrollRequest] = []
        var pending: [PendingRemote] = []
    }

    let local = LocalLane()
    let remote = RemoteLane()
    let deadline = TerminalInteractionDeadlineSignal()
    var delivered: [MobileTerminalRenderGridFrame] = []
    var acceptedRenderRevisions: [UInt64] = []
    var prepareIntentCount = 0
    var reconciliationCompletionCount = 0
    var cancelLocalCount = 0
    var bottomSnapCount = 0
    var replayEpochs: [UInt64] = []
    var epoch: UInt64 = 1

    func makeSession(supportsOrderedRemoteRuns: Bool = false) -> TerminalScrollSession {
        TerminalScrollSession(
            surfaceID: "surface-1",
            interactionEpoch: epoch,
            enqueueLocal: { [local] runs in
                let latest = runs.last
                local.started.append(LocalStarted(
                    lines: runs.reduce(0) { $0 + $1.lines },
                    primaryRows: runs.allSatisfy { $0.primaryRows != nil }
                        ? runs.reduce(0) { $0 + ($1.primaryRows ?? 0) }
                        : nil,
                    col: latest?.col ?? 0,
                    row: latest?.row ?? 0
                ))
                let receipt = TerminalSurfaceMutationReceipt()
                local.pending.append(PendingLocal(
                    continuation: LocalReceiptContinuation(receipt: receipt)
                ))
                return receipt
            },
            enqueueBarrier: {
                let receipt = TerminalSurfaceMutationReceipt()
                receipt.resolve(true)
                return receipt
            },
            enqueueScrollToBottom: { [weak self] in
                self?.bottomSnapCount += 1
                let receipt = TerminalSurfaceMutationReceipt()
                receipt.resolve(true)
                return receipt
            },
            cancelLocal: { [weak self] in
                self?.cancelLocalCount += 1
            },
            sendRemote: { [remote] request in
                remote.started.append(request)
                return await withCheckedContinuation { continuation in
                    remote.pending.append(PendingRemote(request: request, continuation: continuation))
                }
            },
            supportsOrderedRemoteRuns: supportsOrderedRemoteRuns,
            interactionDeadline: { [deadline] _ in await deadline.wait() },
            prepareIntent: { [weak self] in
                self?.prepareIntentCount += 1
            },
            deliverAuthoritative: { [weak self] renderGrid, _, _, _ in
                self?.delivered.append(renderGrid.frame)
                return true
            },
            completeGridlessAuthoritative: { [weak self] revision in
                if let revision {
                    self?.acceptedRenderRevisions.append(revision)
                }
                return true
            },
            reconciliationDidComplete: { [weak self] _ in
                self?.reconciliationCompletionCount += 1
            },
            requestReplay: { [weak self] epoch in
                self?.replayEpochs.append(epoch)
            },
            advanceEpoch: { [weak self] in
                guard let self else { return 0 }
                self.epoch += 1
                return self.epoch
            }
        )
    }
}
