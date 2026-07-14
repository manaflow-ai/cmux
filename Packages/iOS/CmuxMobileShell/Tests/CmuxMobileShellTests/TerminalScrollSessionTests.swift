import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
@Suite("Terminal scroll session")
struct TerminalScrollSessionTests {
    @Test("authoritative response waits for matching local revision")
    func responseWaitsForLocalRevision() async throws {
        let harness = TerminalScrollSessionHarness()
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
        let harness = TerminalScrollSessionHarness()
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

        let harness = TerminalScrollSessionHarness()
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
        harness.local.pending.removeFirst().continuation.resume(returning: true)
        try await requireEventually { harness.delivered.count == 1 }
        session.authoritativeDidApply(
            interactionEpoch: firstRemote.request.interactionEpoch,
            clientRevision: firstRemote.request.clientRevision
        )
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
        #expect(finalRemote.request.prefetchWindow == nil)
        finalRemote.continuation.resume(returning: response(for: finalRemote.request, renderRevision: 30))

        #expect(harness.local.started.map(\.lines) == [10, -10, 5])
        while !harness.local.pending.isEmpty {
            harness.local.pending.removeFirst().continuation.resume(returning: true)
        }
        try await requireEventually { harness.delivered.count == 2 }
        session.authoritativeDidApply(
            interactionEpoch: finalRemote.request.interactionEpoch,
            clientRevision: finalRemote.request.clientRevision
        )
        try await requireEventually { harness.remote.pending.count == 1 }
        let settlementRemote = harness.remote.pending.removeFirst()
        #expect(settlementRemote.request.lines == 0)
        #expect(settlementRemote.request.directionalRuns.isEmpty)
        #expect(settlementRemote.request.prefetchWindow == .directional(for: 5))
        settlementRemote.continuation.resume(returning: response(
            for: settlementRemote.request,
            renderRevision: 40
        ))
        try await requireEventually { harness.delivered.count == 3 }
        session.authoritativeDidApply(
            interactionEpoch: settlementRemote.request.interactionEpoch,
            clientRevision: settlementRemote.request.clientRevision
        )
        try await requireEventually {
            guard case .idle = session.phase else { return false }
            return session.queuedInteractionCount == 0
        }

        #expect(harness.remote.started.map(\.lines) == [10, -10, 5, 0])
        #expect(harness.remote.started.dropLast().allSatisfy { $0.directionalRuns.count == 1 })
        #expect(harness.delivered.map(\.renderRevision) == [10, 30, 40])
    }

    @Test("legacy host uses matching scalar semantics locally and remotely")
    func legacyHostDropsExactRowsBeforeOptimisticApply() async throws {
        let harness = TerminalScrollSessionHarness()
        let session = harness.makeSession(supportsOrderedRemoteRuns: false)

        session.submit(MobileTerminalScrollRun(
            primaryRows: 9,
            alternateScreenLines: 3,
            col: 4,
            row: 5
        ))
        try await requireEventually {
            harness.remote.pending.count == 1 && harness.local.pending.count == 1
        }

        let local = try #require(harness.local.started.first)
        let remote = try #require(harness.remote.started.first)
        #expect(local.lines == 3)
        #expect(local.primaryRows == nil)
        #expect(remote.lines == 3)
        #expect(remote.primaryRows == nil)
        #expect(remote.directionalRuns.first?.primaryRows == nil)
        #expect(remote.wireEncoding == .legacyScalar)

        let pendingRemote = harness.remote.pending.removeFirst()
        pendingRemote.continuation.resume(returning: response(
            for: pendingRemote.request,
            renderRevision: 10
        ))
        harness.local.pending.removeFirst().continuation.resume(returning: true)
        try await requireEventually { harness.delivered.count == 1 }
        session.authoritativeDidApply(
            interactionEpoch: pendingRemote.request.interactionEpoch,
            clientRevision: pendingRemote.request.clientRevision
        )
    }

    @Test("ordered-run capability updates only between interaction plans")
    func orderedRunCapabilityUpdateWaitsForIdleLane() async throws {
        let harness = TerminalScrollSessionHarness()
        let session = harness.makeSession(supportsOrderedRemoteRuns: false)
        session.updateSupportsOrderedRemoteRuns(true)

        session.submit(MobileTerminalScrollRun(
            primaryRows: 9,
            alternateScreenLines: 3,
            col: 4,
            row: 5
        ))
        try await requireEventually {
            harness.remote.pending.count == 1 && harness.local.pending.count == 1
        }
        #expect(harness.local.started.first?.primaryRows == 9)
        #expect(harness.remote.started.first?.primaryRows == 9)
        #expect(harness.remote.started.first?.wireEncoding == .orderedRuns)

        session.updateSupportsOrderedRemoteRuns(false)
        #expect(session.supportsOrderedRemoteRuns)
        let firstRemote = harness.remote.pending.removeFirst()
        firstRemote.continuation.resume(returning: response(
            for: firstRemote.request,
            renderRevision: 10
        ))
        harness.local.pending.removeFirst().continuation.resume(returning: true)
        try await requireEventually { harness.delivered.count == 1 }
        session.authoritativeDidApply(
            interactionEpoch: firstRemote.request.interactionEpoch,
            clientRevision: firstRemote.request.clientRevision
        )
        #expect(!session.supportsOrderedRemoteRuns)

        session.submit(MobileTerminalScrollRun(
            primaryRows: 12,
            alternateScreenLines: 4,
            col: 4,
            row: 5
        ))
        try await requireEventually {
            harness.remote.pending.count == 1 && harness.local.pending.count == 1
        }
        #expect(harness.local.started.last?.primaryRows == nil)
        #expect(harness.remote.started.last?.primaryRows == nil)
        #expect(harness.remote.started.last?.wireEncoding == .legacyScalar)

        let secondRemote = harness.remote.pending.removeFirst()
        secondRemote.continuation.resume(returning: response(
            for: secondRemote.request,
            renderRevision: 20
        ))
        harness.local.pending.removeFirst().continuation.resume(returning: true)
        try await requireEventually { harness.delivered.count == 2 }
        session.authoritativeDidApply(
            interactionEpoch: secondRemote.request.interactionEpoch,
            clientRevision: secondRemote.request.clientRevision
        )
    }

    @Test("journal overflow enters replay recovery without stuck reconciliation")
    func journalOverflowRecoversCleanly() async throws {
        let harness = TerminalScrollSessionHarness()
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
        let harness = TerminalScrollSessionHarness()
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
        let harness = TerminalScrollSessionHarness()
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
        let harness = TerminalScrollSessionHarness()
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

    @Test("gridless settlement preserves a pending authoritative frame")
    func gridlessSettlementPreservesPendingFrame() async throws {
        let harness = TerminalScrollSessionHarness()
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
