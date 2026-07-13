import CMUXMobileCore
import Foundation
import Testing

@testable import CmuxMobileShell

@MainActor
@Suite("Terminal scroll click causality")
struct TerminalScrollClickCausalityTests {
    @Test("click waits for authoritative scroll apply and a surface barrier")
    func clickWaitsForReconciliationAndBarrier() async throws {
        let harness = ClickCausalityHarness()
        let session = harness.makeSession()

        session.submit(lines: -12, col: 2, row: 3)
        let local = try #require(harness.localReceipts.first)
        local.resolve(true)
        try await requireEventually { harness.remoteScrolls.count == 1 }
        let remote = harness.remoteScrolls.removeFirst()
        remote.continuation.resume(returning: harness.response(for: remote.request))
        try await requireEventually {
            harness.deliveredReconciliations == [ClickCausalityHarness.Reconciliation(epoch: 1, revision: 1)]
        }

        session.submitClick(col: 7, row: 9)

        #expect(session.interactionEpoch == 1)
        #expect(harness.barrierReceipts.isEmpty)
        #expect(harness.remoteClicks.isEmpty)

        session.authoritativeDidApply(interactionEpoch: 1, clientRevision: 1)
        try await requireEventually { harness.barrierReceipts.count == 1 }
        #expect(session.interactionEpoch == 1)
        #expect(harness.remoteClicks.isEmpty)

        harness.barrierReceipts[0].resolve(true)
        try await requireEventually { harness.remoteClicks.count == 1 }
        #expect(session.interactionEpoch == 2)
        #expect(harness.remoteClicks[0].epoch == 2)
        #expect(harness.remoteClicks[0].col == 7)
        #expect(harness.remoteClicks[0].row == 9)
    }

    @Test("scroll submitted during a pending click cannot overtake it")
    func scrollAfterPendingClickWaitsForClick() async throws {
        let harness = ClickCausalityHarness()
        let session = harness.makeSession()

        session.submitClick(col: 5, row: 6)
        try await requireEventually { harness.barrierReceipts.count == 1 }
        harness.barrierReceipts[0].resolve(true)
        try await requireEventually { harness.remoteClicks.count == 1 }

        session.submit(lines: 4, col: 8, row: 10)

        #expect(harness.localReceipts.isEmpty)
        #expect(harness.remoteScrolls.isEmpty)
        #expect(session.latestClientRevision == 0)

        harness.remoteClicks[0].continuation.resume(returning: true)
        try await requireEventually {
            harness.localReceipts.count == 1 && harness.remoteScrolls.count == 1
        }
        #expect(harness.remoteScrolls[0].request.interactionEpoch == 2)
        #expect(harness.remoteScrolls[0].request.clientRevision == 1)
    }

    @Test("rapid taps preserve every click in order")
    func rapidTapsPreserveOrder() async throws {
        let harness = ClickCausalityHarness()
        let session = harness.makeSession()

        session.submitClick(col: 1, row: 2)
        session.submitClick(col: 3, row: 4)
        session.submitClick(col: 5, row: 6)

        for index in 0..<3 {
            try await requireEventually { harness.barrierReceipts.count == index + 1 }
            harness.barrierReceipts[index].resolve(true)
            try await requireEventually { harness.remoteClicks.count == index + 1 }
            harness.remoteClicks[index].continuation.resume(returning: true)
        }
        try await requireEventually {
            if case .idle = session.phase { return true }
            return false
        }

        #expect(harness.remoteClicks.map(\.col) == [1, 3, 5])
        #expect(harness.remoteClicks.map(\.row) == [2, 4, 6])
        #expect(harness.remoteClicks.map(\.epoch) == [2, 3, 4])
    }

    @Test("double tap submitted while the first click is sending is retained")
    func inFlightDoubleTapIsRetained() async throws {
        let harness = ClickCausalityHarness()
        let session = harness.makeSession()

        session.submitClick(col: 7, row: 8)
        try await requireEventually { harness.barrierReceipts.count == 1 }
        harness.barrierReceipts[0].resolve(true)
        try await requireEventually { harness.remoteClicks.count == 1 }

        session.submitClick(col: 9, row: 10)
        harness.remoteClicks[0].continuation.resume(returning: true)

        try await requireEventually { harness.barrierReceipts.count == 2 }
        harness.barrierReceipts[1].resolve(true)
        try await requireEventually { harness.remoteClicks.count == 2 }
        #expect(harness.remoteClicks[1].col == 9)
        #expect(harness.remoteClicks[1].row == 10)
        harness.remoteClicks[1].continuation.resume(returning: true)
        try await requireEventually {
            if case .idle = session.phase { return true }
            return false
        }
    }

    @Test("click queue overflow recovers instead of growing or dropping silently")
    func clickQueueOverflowRecovers() {
        let harness = ClickCausalityHarness()
        let session = harness.makeSession()

        session.submitClick(col: 0, row: 0)
        for index in 0..<TerminalScrollSession.maximumQueuedInteractionCount {
            session.submitClick(col: index + 1, row: index + 1)
        }
        #expect(harness.replayEpochs.isEmpty)

        session.submitClick(col: 100, row: 100)

        #expect(harness.replayEpochs == [2])
        #expect(session.interactionEpoch == 2)
    }

    private func requireEventually(_ condition: @MainActor () async -> Bool) async throws {
        try #require(await pollUntil(condition))
    }
}

@MainActor
private final class ClickCausalityHarness {
    struct Reconciliation: Equatable {
        let epoch: UInt64
        let revision: UInt64
    }

    struct PendingScroll {
        let request: TerminalScrollRequest
        let continuation: CheckedContinuation<TerminalScrollResponse?, Never>
    }

    struct PendingClick {
        let epoch: UInt64
        let col: Int
        let row: Int
        let continuation: CheckedContinuation<Bool, Never>
    }

    var localReceipts: [TerminalSurfaceMutationReceipt] = []
    var barrierReceipts: [TerminalSurfaceMutationReceipt] = []
    var remoteScrolls: [PendingScroll] = []
    var remoteClicks: [PendingClick] = []
    var deliveredReconciliations: [Reconciliation] = []
    var replayEpochs: [UInt64] = []
    var epoch: UInt64 = 1
    let deadline = TerminalInteractionDeadlineSignal()

    func makeSession() -> TerminalScrollSession {
        TerminalScrollSession(
            surfaceID: "surface-1",
            interactionEpoch: epoch,
            enqueueLocal: { [weak self] _ in
                let receipt = TerminalSurfaceMutationReceipt()
                self?.localReceipts.append(receipt)
                return receipt
            },
            enqueueBarrier: { [weak self] in
                let receipt = TerminalSurfaceMutationReceipt()
                self?.barrierReceipts.append(receipt)
                return receipt
            },
            enqueueScrollToBottom: {
                let receipt = TerminalSurfaceMutationReceipt()
                receipt.resolve(true)
                return receipt
            },
            cancelLocal: {},
            sendRemote: { [weak self] request in
                await withCheckedContinuation { continuation in
                    self?.remoteScrolls.append(PendingScroll(
                        request: request,
                        continuation: continuation
                    ))
                }
            },
            sendClick: { [weak self] _, epoch, col, row in
                await withCheckedContinuation { continuation in
                    self?.remoteClicks.append(PendingClick(
                        epoch: epoch,
                        col: col,
                        row: row,
                        continuation: continuation
                    ))
                }
            },
            interactionDeadline: { [deadline] _ in await deadline.wait() },
            prepareIntent: {},
            deliverAuthoritative: { [weak self] _, epoch, revision in
                self?.deliveredReconciliations.append(Reconciliation(epoch: epoch, revision: revision))
                return true
            },
            completeGridlessAuthoritative: { _ in true },
            reconciliationDidComplete: {},
            requestReplay: { [weak self] epoch in
                self?.replayEpochs.append(epoch)
            },
            advanceEpoch: { [weak self] in
                guard let self else { return 0 }
                epoch += 1
                return epoch
            }
        )
    }

    func response(for request: TerminalScrollRequest) -> TerminalScrollResponse {
        TerminalScrollResponse(
            accepted: true,
            interactionEpoch: request.interactionEpoch,
            clientRevision: request.clientRevision,
            renderRevision: request.clientRevision,
            renderGrid: try! MobileTerminalRenderGridFrame.fromPlainRows(
                surfaceID: request.surfaceID,
                stateSeq: request.clientRevision,
                renderRevision: request.clientRevision,
                columns: 20,
                rows: 2,
                text: "authoritative\nviewport"
            )
        )
    }
}
