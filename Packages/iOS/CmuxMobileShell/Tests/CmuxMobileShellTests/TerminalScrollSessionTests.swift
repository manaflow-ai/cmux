import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
@Suite("Terminal scroll session")
struct TerminalScrollSessionTests {
    @Test("authoritative response waits for matching local revision")
    func responseWaitsForLocalRevision() async throws {
        let harness = Harness()
        let session = harness.makeSession()

        session.submit(lines: 24, col: 2, row: 3)
        try await requireEventually {
            harness.remote.pending.count == 1 && harness.local.pending.count == 1
        }
        let remote = try #require(harness.remote.pending.first)
        harness.remote.pending.removeFirst()
        remote.continuation.resume(returning: response(for: remote.request, renderRevision: 10))

        #expect(harness.delivered.isEmpty)
        #expect(session.shouldDeferLiveRenderGrid)

        let local = try #require(harness.local.pending.first)
        harness.local.pending.removeFirst()
        local.continuation.resume(returning: true)
        try await requireEventually { harness.delivered.count == 1 }

        #expect(harness.delivered.map(\.renderRevision) == [10])
        #expect(session.shouldDeferLiveRenderGrid)
        #expect(session.latestReconciledRevision == 0)

        session.authoritativeDidApply(interactionEpoch: 1, clientRevision: 1)
        #expect(!session.shouldDeferLiveRenderGrid)
        #expect(session.latestReconciledRevision == 1)
    }

    @Test("accepted response without a frame advances the render floor")
    func responseWithoutFrameAdvancesRenderFloor() async throws {
        let harness = Harness()
        let session = harness.makeSession()

        session.submit(lines: -6, col: 1, row: 1)
        try await requireEventually {
            harness.remote.pending.count == 1 && harness.local.pending.count == 1
        }
        let remote = try #require(harness.remote.pending.first)
        harness.remote.pending.removeFirst()
        remote.continuation.resume(returning: TerminalScrollResponse(
            accepted: true,
            interactionEpoch: remote.request.interactionEpoch,
            clientRevision: remote.request.clientRevision,
            renderRevision: 12,
            renderGrid: nil
        ))
        let local = try #require(harness.local.pending.first)
        harness.local.pending.removeFirst()
        local.continuation.resume(returning: true)
        try await requireEventually { harness.reconciliationCompletionCount == 1 }

        #expect(harness.delivered.isEmpty)
        #expect(harness.acceptedRenderRevisions == [12])
        #expect(harness.reconciliationCompletionCount == 1)
        #expect(!session.shouldDeferLiveRenderGrid)
        #expect(session.latestReconciledRevision == 1)
    }

    @Test("capable host splits 65 ordered runs into bounded RPCs")
    func capableHostSplitsLargeOrderedJournal() throws {
        let request = try makeRequest(lines: (0..<65).map { $0.isMultiple(of: 2) ? 3 : -2 })

        let planned = request.plannedRPCRequests(supportsOrderedRuns: true)

        #expect(planned.map(\.directionalRuns.count) == [32, 32, 1])
        #expect(planned.allSatisfy { $0.wireEncoding == .orderedRuns })
        #expect(planned.dropLast().allSatisfy { $0.prefetchWindow == nil })
        #expect(planned.last?.prefetchWindow == request.prefetchWindow)
        #expect(planned.flatMap(\.directionalRuns).map(\.lines) == request.directionalRuns.map(\.lines))
    }

    @Test("capable host sends one ordered batch when within the wire limit")
    func capableHostUsesSingleOrderedBatch() throws {
        let request = try makeRequest(lines: [10, -10, 5])

        let planned = request.plannedRPCRequests(supportsOrderedRuns: true)

        #expect(planned.count == 1)
        #expect(planned.first?.wireEncoding == .orderedRuns)
        #expect(planned.first?.directionalRuns.map(\.lines) == [10, -10, 5])
        #expect(planned.first?.prefetchWindow == request.prefetchWindow)
    }

    @Test("unresolved or legacy host sends exact scalar run order")
    func legacyHostUsesSequentialScalarRequests() async throws {
        let request = try makeRequest(lines: [10, -10, 5])

        let planned = request.plannedRPCRequests(supportsOrderedRuns: false)

        #expect(planned.map(\.wireEncoding) == [.legacyScalar, .legacyScalar, .legacyScalar])
        #expect(planned.map(\.lines) == [10, -10, 5])
        #expect(planned.map { $0.directionalRuns.map(\.lines) } == [[10], [-10], [5]])
        #expect(planned[0].prefetchWindow == nil)
        #expect(planned[1].prefetchWindow == nil)
        #expect(planned[2].prefetchWindow == request.prefetchWindow)

        let harness = Harness()
        let session = harness.makeSession()
        session.submit(lines: 10, col: 1, row: 1)
        try await requireEventually {
            harness.remote.pending.count == 1 && harness.local.pending.count == 1
        }
        session.submit(lines: -10, col: 2, row: 2)
        session.submit(lines: 5, col: 3, row: 3)
        session.interactionDidEnd()

        let firstRemote = harness.remote.pending.removeFirst()
        firstRemote.continuation.resume(returning: response(for: firstRemote.request, renderRevision: 10))
        try await requireEventually { harness.remote.pending.count == 1 }
        let secondRemote = harness.remote.pending.removeFirst()
        #expect(secondRemote.request.lines == -10)
        #expect(secondRemote.request.wireEncoding == .legacyScalar)
        #expect(secondRemote.request.prefetchWindow == nil)
        secondRemote.continuation.resume(returning: response(for: secondRemote.request, renderRevision: 20))
        try await requireEventually { harness.remote.pending.count == 1 }
        let finalRemote = harness.remote.pending.removeFirst()
        #expect(finalRemote.request.lines == 5)
        #expect(finalRemote.request.wireEncoding == .legacyScalar)
        #expect(finalRemote.request.prefetchWindow == .directional(for: 5))
        finalRemote.continuation.resume(returning: response(for: finalRemote.request, renderRevision: 30))

        #expect(harness.local.started.map(\.lines) == [10, -10, 5])
        while !harness.local.pending.isEmpty {
            harness.local.pending.removeFirst().continuation.resume(returning: true)
        }
        try await requireEventually { harness.delivered.count == 1 }

        #expect(harness.remote.started.map(\.lines) == [10, -10, 5])
        #expect(harness.remote.started.allSatisfy { $0.directionalRuns.count == 1 })
        #expect(harness.delivered.map(\.renderRevision) == [30])
    }

    @Test("journal overflow enters replay recovery without stuck reconciliation")
    func journalOverflowRecoversCleanly() async throws {
        let harness = Harness()
        let session = harness.makeSession()

        session.submit(lines: 10, col: 1, row: 1)
        try await requireEventually {
            harness.remote.pending.count == 1 && harness.local.pending.count == 1
        }
        for index in 1...65 {
            session.submit(
                lines: index.isMultiple(of: 2) ? 3 : -2,
                col: index,
                row: index + 1
            )
            if !harness.replayEpochs.isEmpty { break }
        }
        #expect(harness.replayEpochs == [2])
        #expect(session.interactionEpoch == 2)
        #expect(session.latestClientRevision == 0)
        #expect(session.latestReconciledRevision == 0)
        #expect(!session.shouldDeferLiveRenderGrid)

        let staleRemote = try #require(harness.remote.pending.first)
        harness.remote.pending.removeFirst()
        staleRemote.continuation.resume(returning: response(for: staleRemote.request, renderRevision: 20))
        let staleLocal = try #require(harness.local.pending.first)
        harness.local.pending.removeFirst()
        staleLocal.continuation.resume(returning: true)
        #expect(harness.delivered.isEmpty)
    }

    @Test("recovery fences old local and remote completions before queued input")
    func recoveryFencesOldCompletionsBeforeInput() async throws {
        let harness = Harness()
        let session = harness.makeSession()

        session.submit(lines: 14, col: 2, row: 4)
        try await requireEventually {
            harness.remote.pending.count == 1 && harness.local.pending.count == 1
        }
        let local = try #require(harness.local.pending.first)
        harness.local.pending.removeFirst()
        let remote = try #require(harness.remote.pending.first)
        harness.remote.pending.removeFirst()

        session.recoverFromLaneFailure()
        _ = session.submitInput(.fence)
        _ = session.submitInput(.fence)
        try await requireEventually { session.interactionEpoch == 4 }
        #expect(harness.replayEpochs == [2])
        #expect(harness.cancelLocalCount == 2)
        #expect(harness.bottomSnapCount == 1)
        #expect(!session.shouldDeferLiveRenderGrid)

        remote.continuation.resume(returning: response(for: remote.request, renderRevision: 30))
        local.continuation.resume(returning: true)

        #expect(harness.delivered.isEmpty)
        #expect(session.latestReconciledRevision == 0)
    }

    @Test("a new scroll episode permits exactly one new input snap")
    func newScrollRearmsInputSnap() async throws {
        let harness = Harness()
        let session = harness.makeSession()

        _ = session.submitInput(.fence)
        _ = session.submitInput(.fence)
        try await requireEventually { session.interactionEpoch == 3 }
        #expect(harness.bottomSnapCount == 1)

        session.submit(lines: -3, col: 2, row: 4)
        try await requireEventually {
            harness.remote.pending.count == 1 && harness.local.pending.count == 1
        }
        let remote = harness.remote.pending.removeFirst()
        let local = harness.local.pending.removeFirst()
        remote.continuation.resume(returning: response(for: remote.request, renderRevision: 20))
        local.continuation.resume(returning: true)
        try await requireEventually { harness.delivered.count == 1 }
        session.authoritativeDidApply(
            interactionEpoch: remote.request.interactionEpoch,
            clientRevision: remote.request.clientRevision
        )
        _ = session.submitInput(.fence)
        _ = session.submitInput(.fence)
        try await requireEventually { session.interactionEpoch == 5 }

        #expect(harness.bottomSnapCount == 2)
        #expect(harness.cancelLocalCount == 4)
    }

    @Test("settlement requests a directional large window without a timer")
    func settlementRequestsDirectionalWindow() async throws {
        let harness = Harness()
        let session = harness.makeSession()

        session.submit(lines: -8, col: 4, row: 5)
        try await requireEventually {
            harness.remote.pending.count == 1 && harness.local.pending.count == 1
        }
        let first = try #require(harness.remote.pending.first)
        harness.remote.pending.removeFirst()
        #expect(first.request.prefetchWindow == TerminalScrollPrefetchWindow(
            rowsBeforeViewport: 120,
            rowsAfterViewport: 600
        ))
        first.continuation.resume(returning: response(for: first.request, renderRevision: 40))
        let local = try #require(harness.local.pending.first)
        harness.local.pending.removeFirst()
        local.continuation.resume(returning: true)
        try await requireEventually { harness.delivered.count == 1 }
        session.authoritativeDidApply(
            interactionEpoch: first.request.interactionEpoch, clientRevision: first.request.clientRevision
        )

        session.interactionDidEnd()
        try await requireEventually { harness.remote.pending.count == 1 }
        let settled = try #require(harness.remote.pending.first)
        #expect(settled.request.lines == 0)
        #expect(settled.request.clientRevision == 1)
        #expect(settled.request.prefetchWindow == TerminalScrollPrefetchWindow(
            rowsBeforeViewport: 120,
            rowsAfterViewport: 600
        ))
    }

    @Test("rolling prefetch counts exact primary rows instead of alternate wheel ticks")
    func rollingPrefetchCountsPrimaryRows() {
        let harness = Harness()
        let session = harness.makeSession()
        let run = MobileTerminalScrollRun(
            primaryRows: 1,
            alternateScreenLines: 0.1,
            col: 1,
            row: 1
        )

        #expect(session.prefetchWindow(for: run) == .directional(for: 1))
        for _ in 0..<119 {
            #expect(session.prefetchWindow(for: run) == nil)
        }
        #expect(session.prefetchWindow(for: run) == .directional(for: 1))
    }

    @Test("gridless settlement preserves a pending authoritative frame")
    func gridlessSettlementPreservesPendingFrame() async throws {
        let harness = Harness()
        let session = harness.makeSession()

        session.submit(lines: -8, col: 4, row: 5)
        try await requireEventually {
            harness.remote.pending.count == 1 && harness.local.pending.count == 1
        }
        let scroll = harness.remote.pending.removeFirst()
        scroll.continuation.resume(returning: response(for: scroll.request, renderRevision: 40))

        session.interactionDidEnd()
        let local = harness.local.pending.removeFirst()
        local.continuation.resume(returning: true)
        try await requireEventually { harness.delivered.count == 1 }
        session.authoritativeDidApply(
            interactionEpoch: scroll.request.interactionEpoch, clientRevision: scroll.request.clientRevision
        )
        try await requireEventually { harness.remote.pending.count == 1 }
        let settlement = harness.remote.pending.removeFirst()
        settlement.continuation.resume(returning: TerminalScrollResponse(
            accepted: true,
            interactionEpoch: settlement.request.interactionEpoch,
            clientRevision: settlement.request.clientRevision,
            renderRevision: 41,
            renderGrid: nil
        ))

        try await requireEventually {
            !harness.delivered.isEmpty || !harness.acceptedRenderRevisions.isEmpty
        }

        #expect(harness.delivered.map(\.renderRevision) == [40])
        #expect(harness.acceptedRenderRevisions.isEmpty)
    }

    @Test("disconnect recovery preserves the mounted session")
    func disconnectRecoveryPreservesMountedSession() {
        let store = MobileShellComposite.preview()
        let surfaceID = "surface-1"
        let token = store.mountTerminalScrollSession(
            surfaceID: surfaceID,
            cancelLocal: {}
        )
        let originalSession = store.terminalScrollSessionsBySurfaceID[surfaceID]
        let originalEpoch = originalSession?.interactionEpoch

        store.remoteClient = nil

        let recoveredSession = store.terminalScrollSessionsBySurfaceID[surfaceID]
        #expect(recoveredSession?.token == token)
        #expect(recoveredSession === originalSession)
        #expect(recoveredSession?.interactionEpoch != originalEpoch)
        #expect(recoveredSession?.shouldDeferLiveRenderGrid == false)

        store.unmountTerminalScrollSession(surfaceID: surfaceID, token: token)
    }

    private func response(
        for request: TerminalScrollRequest,
        renderRevision: UInt64
    ) -> TerminalScrollResponse {
        TerminalScrollResponse(
            accepted: true,
            interactionEpoch: request.interactionEpoch,
            clientRevision: request.clientRevision,
            renderRevision: renderRevision,
            renderGrid: try! MobileTerminalRenderGridFrame.fromPlainRows(
                surfaceID: request.surfaceID,
                stateSeq: 5,
                renderRevision: renderRevision,
                columns: 20,
                rows: 2,
                text: "row-a\nrow-b"
            )
        )
    }

    private func makeRequest(lines: [Double]) throws -> TerminalScrollRequest {
        let first = try #require(lines.first)
        var request = TerminalScrollRequest(
            surfaceID: "surface-1",
            interactionEpoch: 1,
            clientRevision: 1,
            lines: first,
            col: 1,
            row: 1,
            prefetchWindow: .directional(for: first)
        )
        for (index, lines) in lines.dropFirst().enumerated() {
            let appended = request.append(TerminalScrollRequest(
                surfaceID: "surface-1",
                interactionEpoch: 1,
                clientRevision: UInt64(index + 2),
                lines: lines,
                col: index + 2,
                row: index + 2,
                prefetchWindow: nil
            ))
            try #require(appended)
        }
        return request
    }

    private func requireEventually(
        _ condition: @MainActor () async -> Bool
    ) async throws {
        try #require(await pollUntil(condition))
    }
}

@MainActor
private final class Harness {
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

    func makeSession() -> TerminalScrollSession {
        TerminalScrollSession(
            surfaceID: "surface-1",
            interactionEpoch: epoch,
            enqueueLocal: { [local] runs in
                let latest = runs.last
                local.started.append(LocalStarted(
                    lines: runs.reduce(0) { $0 + $1.lines },
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
            interactionDeadline: { [deadline] _ in await deadline.wait() },
            prepareIntent: { [weak self] in
                self?.prepareIntentCount += 1
            },
            deliverAuthoritative: { [weak self] frame, _, _, _ in
                self?.delivered.append(frame)
                return true
            },
            completeGridlessAuthoritative: { [weak self] revision in
                if let revision {
                    self?.acceptedRenderRevisions.append(revision)
                }
                return true
            },
            reconciliationDidComplete: { [weak self] in
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
