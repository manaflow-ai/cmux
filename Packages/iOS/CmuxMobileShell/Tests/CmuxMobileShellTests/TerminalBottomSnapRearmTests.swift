import CMUXMobileCore
import Foundation
import Testing

@testable import CmuxMobileShell

@MainActor
@Suite("Terminal bottom snap rearm")
struct TerminalBottomSnapRearmTests {
    @Test("scroll queued behind a pending snap rearms exactly one later snap")
    func queuedScrollRearmsBottomSnap() async throws {
        let harness = BottomSnapRearmHarness()
        let session = harness.makeSession()
        let firstInput = session.submitInput(.fence)
        try #require(await pollUntil { harness.snapReceipts.count == 1 }, "first snap")

        for _ in 0..<12 {
            session.submit(lines: -1, col: 1, row: 1)
        }
        harness.snapReceipts[0].resolve(true)

        #expect(await firstInput.value)
        try #require(await pollUntil { harness.scrollRequests.count == 1 }, "scroll request")
        try #require(await pollUntil { session.phase.isIdle }, "scroll completion")
        #expect(harness.scrollRequests[0].directionalRuns.map(\.lines) == [-12])

        let secondInput = session.submitInput(.fence)
        try #require(await pollUntil { harness.snapReceipts.count == 2 }, "rearmed snap")
        harness.snapReceipts[1].resolve(true)

        #expect(await secondInput.value)
        #expect(harness.snapReceipts.count == 2)

        let repeatedInput = session.submitInput(.fence)
        #expect(await repeatedInput.value)
        #expect(harness.snapReceipts.count == 2)
    }
}

private extension TerminalScrollSession.Phase {
    var isIdle: Bool {
        if case .idle = self { return true }
        return false
    }
}

@MainActor
private final class BottomSnapRearmHarness {
    let deadline = TerminalInteractionDeadlineSignal()
    var snapReceipts: [TerminalSurfaceMutationReceipt] = []
    var scrollRequests: [TerminalScrollRequest] = []
    var epoch: UInt64 = 1

    func makeSession() -> TerminalScrollSession {
        TerminalScrollSession(
            surfaceID: "bottom-snap-rearm",
            interactionEpoch: epoch,
            enqueueLocal: { _ in Self.resolvedReceipt() },
            enqueueBarrier: { Self.resolvedReceipt() },
            enqueueScrollToBottom: { [weak self] in
                let receipt = TerminalSurfaceMutationReceipt()
                self?.snapReceipts.append(receipt)
                return receipt
            },
            cancelLocal: {},
            sendRemote: { [weak self] request in
                self?.scrollRequests.append(request)
                return TerminalScrollResponse(
                    accepted: true,
                    interactionEpoch: request.interactionEpoch,
                    clientRevision: request.clientRevision,
                    renderRevision: request.clientRevision,
                    renderGrid: nil
                )
            },
            interactionDeadline: { [deadline] _ in await deadline.wait() },
            prepareIntent: {},
            deliverAuthoritative: { _, _, _ in true },
            completeGridlessAuthoritative: { _ in true },
            reconciliationDidComplete: {},
            requestReplay: { _ in },
            advanceEpoch: { [weak self] in
                guard let self else { return 0 }
                epoch += 1
                return epoch
            }
        )
    }

    private static func resolvedReceipt() -> TerminalSurfaceMutationReceipt {
        let receipt = TerminalSurfaceMutationReceipt()
        receipt.resolve(true)
        return receipt
    }
}
