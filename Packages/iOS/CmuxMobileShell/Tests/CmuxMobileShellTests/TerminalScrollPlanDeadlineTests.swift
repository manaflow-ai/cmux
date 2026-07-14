import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
@Suite("Terminal scroll plan deadline")
struct TerminalScrollPlanDeadlineTests {
    @Test("multiple planned RPCs receive a bounded aggregate deadline")
    func multipleRPCsCompleteWithinPlanBudget() async throws {
        let harness = ScrollPlanDeadlineHarness()
        let session = harness.makeSession()
        startScrollPlan([8, -5, 3], in: session)

        try await requireEventually {
            harness.deadline.budgets == [.milliseconds(600)]
                && harness.remote.pending.count == 1
                && harness.localReceipts.count == 1
        }
        harness.localReceipts.removeFirst().resolve(true)
        for expectedLines in [8.0, -5.0, 3.0] {
            let pending = try #require(harness.remote.pending.first)
            harness.remote.pending.removeFirst()
            #expect(pending.request.lines == expectedLines)
            pending.continuation.resume(returning: harness.response(for: pending.request))
            if expectedLines != 3 {
                try await requireEventually { harness.remote.pending.count == 1 }
            }
        }
        try await requireEventually { !session.shouldDeferLiveRenderGrid }

        #expect(harness.replayEpochs.isEmpty)
        #expect(session.latestReconciledRevision == 3)
    }

    @Test("scroll plan deadline caps recovery independently of journal size")
    func planBudgetIsCappedAndRecovers() async throws {
        #expect(
            TerminalScrollSession.interactionPlanDeadlineDuration(plannedRequestCount: 64)
                == .milliseconds(600)
        )
        let harness = ScrollPlanDeadlineHarness()
        let session = harness.makeSession()
        startScrollPlan([8, -5, 3, -2], in: session)

        try await requireEventually {
            harness.deadline.budgets == [.milliseconds(600)]
                && harness.remote.pending.count == 1
        }
        harness.deadline.fire()
        try await requireEventually { harness.replayEpochs == [2] }

        #expect(!session.shouldDeferLiveRenderGrid)
        let abandoned = harness.remote.pending.removeFirst()
        abandoned.continuation.resume(returning: nil)
        harness.localReceipts.removeFirst().resolve(false)
    }

    @Test("legacy scalar plans roll into bounded transactions without dropping their suffix")
    func legacyScalarPlanRollsDeadlineAfterThreeRequests() async throws {
        let harness = ScrollPlanDeadlineHarness()
        let session = harness.makeSession()
        startScrollPlan([8, -5, 3, -2], in: session)

        try await requireEventually {
            harness.deadline.budgets == [.milliseconds(600)]
                && harness.remote.pending.count == 1
                && harness.localReceipts.count == 1
        }
        harness.localReceipts.removeFirst().resolve(true)

        for (index, expectedLines) in [8.0, -5.0, 3.0].enumerated() {
            let pending = try #require(harness.remote.pending.first)
            harness.remote.pending.removeFirst()
            #expect(pending.request.lines == expectedLines)
            #expect(pending.request.col == index + 1)
            #expect(pending.request.row == index + 2)
            pending.continuation.resume(returning: harness.response(for: pending.request))
            try await requireEventually { harness.remote.pending.count == 1 }
        }

        try await requireEventually {
            harness.deadline.budgets == [.milliseconds(600), .milliseconds(200)]
        }
        let suffix = try #require(harness.remote.pending.first)
        harness.remote.pending.removeFirst()
        #expect(suffix.request.lines == -2)
        #expect(suffix.request.col == 4)
        #expect(suffix.request.row == 5)
        suffix.continuation.resume(returning: harness.response(for: suffix.request))

        try await requireEventually { !session.shouldDeferLiveRenderGrid }
        #expect(harness.replayEpochs.isEmpty)
        #expect(session.latestReconciledRevision == 4)
    }

    private func startScrollPlan(_ lines: [Double], in session: TerminalScrollSession) {
        let runs = lines.enumerated().map { index, lines in
            MobileTerminalScrollRun(lines: lines, col: index + 1, row: index + 2)
        }
        let appended = session.intents.append(.scroll(.init(
            runs: runs,
            submissionCount: runs.count,
            localReceipts: []
        )))
        #expect(appended)
        session.queuedInteractionCount = 1
        session.startNextIntentIfIdle()
    }

    private func requireEventually(
        _ condition: @MainActor () async -> Bool
    ) async throws {
        try #require(await pollUntil(condition))
    }
}

@MainActor
private final class ScrollPlanDeadlineHarness {
    struct PendingRemote {
        let request: TerminalScrollRequest
        let continuation: CheckedContinuation<TerminalScrollResponse?, Never>
    }

    final class RemoteLane {
        var pending: [PendingRemote] = []
    }

    let deadline = ScrollPlanDeadlineSignal()
    let remote = RemoteLane()
    var localReceipts: [TerminalSurfaceMutationReceipt] = []
    var replayEpochs: [UInt64] = []
    var epoch: UInt64 = 1

    func makeSession() -> TerminalScrollSession {
        TerminalScrollSession(
            surfaceID: "surface-1",
            interactionEpoch: epoch,
            enqueueLocal: { [weak self] _ in
                let receipt = TerminalSurfaceMutationReceipt()
                self?.localReceipts.append(receipt)
                return receipt
            },
            enqueueBarrier: { Self.resolvedReceipt() },
            enqueueScrollToBottom: { Self.resolvedReceipt() },
            cancelLocal: {},
            sendRemote: { [remote] request in
                await withCheckedContinuation { continuation in
                    remote.pending.append(.init(request: request, continuation: continuation))
                }
            },
            supportsOrderedRemoteRuns: false,
            interactionDeadline: { [deadline] duration in
                await deadline.wait(for: duration)
            },
            prepareIntent: {},
            deliverAuthoritative: { _, _, _, _ in false },
            completeGridlessAuthoritative: { _ in true },
            reconciliationDidComplete: {},
            requestReplay: { [weak self] epoch in self?.replayEpochs.append(epoch) },
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
            renderGrid: nil
        )
    }

    private static func resolvedReceipt() -> TerminalSurfaceMutationReceipt {
        let receipt = TerminalSurfaceMutationReceipt()
        receipt.resolve(true)
        return receipt
    }
}

@MainActor
private final class ScrollPlanDeadlineSignal {
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private(set) var budgets: [Duration] = []

    func wait(for duration: Duration) async {
        budgets.append(duration)
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiters[id] = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.resolve(id) }
        }
    }

    func fire() {
        let pending = waiters.values
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }

    private func resolve(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume()
    }
}
