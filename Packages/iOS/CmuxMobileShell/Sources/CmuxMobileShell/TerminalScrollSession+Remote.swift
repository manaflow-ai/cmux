import CMUXMobileCore
import Foundation

extension TerminalScrollSession {
    func startNextIntentIfIdle() {
        guard case .idle = phase else { return }
        guard let intent = removeNextIntent() else {
            applyPendingOrderedRunSupportIfIdle()
            return
        }
        switch intent {
        case .scroll(let scroll): startScroll(scroll)
        case .settlement: startSettlement()
        case .click(let col, let row): startClick(col: col, row: row)
        case .input(let input): startInput(input)
        }
    }

    private func startScroll(_ scroll: ScrollIntent) {
        guard let first = scroll.runs.first else {
            startNextIntentIfIdle()
            return
        }
        prepareIntent()
        lastDirectionLines = first.directionValue
        lastCol = first.col
        lastRow = first.row
        var nextRevision = latestClientRevision &+ UInt64(scroll.submissionCount)
        if nextRevision == 0 { nextRevision = 1 }
        var request = TerminalScrollRequest(
            surfaceID: surfaceID,
            interactionEpoch: interactionEpoch,
            clientRevision: nextRevision,
            lines: first.lines,
            primaryRows: first.primaryRows,
            col: first.col,
            row: first.row,
            prefetchWindow: prefetchWindow(for: first)
        )
        for run in scroll.runs.dropFirst() {
            let appended = request.append(TerminalScrollRequest(
                surfaceID: surfaceID,
                interactionEpoch: interactionEpoch,
                clientRevision: nextRevision,
                lines: run.lines,
                primaryRows: run.primaryRows,
                col: run.col,
                row: run.row,
                prefetchWindow: prefetchWindow(for: run)
            ))
            guard appended else {
                recoverFromLaneFailure()
                return
            }
            lastDirectionLines = run.directionValue
            lastCol = run.col
            lastRow = run.row
        }
        latestClientRevision = nextRevision
        startScrollTransaction(
            request,
            localReceipts: scroll.localReceipts
        )
    }

    private func startSettlement() {
        guard latestClientRevision > 0 else {
            startNextIntentIfIdle()
            return
        }
        let request = TerminalScrollRequest(
            surfaceID: surfaceID,
            interactionEpoch: interactionEpoch,
            clientRevision: latestClientRevision,
            lines: 0,
            col: lastCol,
            row: lastRow,
            prefetchWindow: .directional(for: lastDirectionLines)
        )
        startScrollTransaction(request, localReceipts: nil)
    }

    private func startScrollTransaction(
        _ request: TerminalScrollRequest,
        localReceipts: [TerminalSurfaceMutationReceipt]?
    ) {
        let id = UUID()
        let requiresLocalApply = localReceipts != nil
        phase = .scroll(ScrollTransaction(
            id: id,
            request: request,
            requiresLocalApply: requiresLocalApply,
            localApplied: !requiresLocalApply
        ))
        let plannedRequestChunks = request.plannedRPCRequestChunks(
            supportsOrderedRuns: supportsOrderedRemoteRuns
        )
        if requiresLocalApply {
            let receipts: [TerminalSurfaceMutationReceipt]
            if let localReceipts, !localReceipts.isEmpty {
                receipts = localReceipts
            } else {
                receipts = [enqueueLocal(request.directionalRuns)]
            }
            localTask = Task { @MainActor [weak self] in
                var applied = true
                for receipt in receipts where applied {
                    applied = await receipt.value
                }
                guard !Task.isCancelled else { return }
                self?.scrollLocalDidComplete(id: id, applied: applied)
            }
        }
        remoteTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var response: TerminalScrollResponse?
            for chunk in plannedRequestChunks {
                self.restartScrollDeadline(id: id, plannedRequestCount: chunk.count)
                for plannedRequest in chunk {
                    guard !Task.isCancelled,
                          let plannedResponse = await self.sendRemote(plannedRequest),
                          plannedResponse.accepted,
                          plannedResponse.interactionEpoch == request.interactionEpoch,
                          plannedResponse.clientRevision == request.clientRevision else {
                        guard !Task.isCancelled else { return }
                        self.scrollRemoteDidComplete(id: id, response: nil, succeeded: false)
                        return
                    }
                    response = plannedResponse
                }
            }
            guard !Task.isCancelled else { return }
            self.cancelScrollDeadline(id: id)
            self.scrollRemoteDidComplete(id: id, response: response, succeeded: true)
        }
    }

    private func restartScrollDeadline(id: UUID, plannedRequestCount: Int) {
        deadlineTask?.cancel()
        deadlineTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.interactionDeadline(Self.interactionPlanDeadlineDuration(
                plannedRequestCount: plannedRequestCount
            ))
            guard !Task.isCancelled else { return }
            self.scrollDeadlineDidFire(id: id)
        }
    }

    private func cancelScrollDeadline(id: UUID) {
        guard case .scroll(let transaction) = phase, transaction.id == id else { return }
        deadlineTask?.cancel()
        deadlineTask = nil
    }

    private func scrollLocalDidComplete(id: UUID, applied: Bool) {
        guard case .scroll(var transaction) = phase, transaction.id == id else { return }
        localTask = nil
        guard applied else {
            recoverFromLaneFailure()
            return
        }
        transaction.localApplied = true
        latestLocallyAppliedRevision = max(
            latestLocallyAppliedRevision,
            transaction.request.clientRevision
        )
        phase = .scroll(transaction)
        reconcileScrollIfReady(id: id)
    }

    private func scrollRemoteDidComplete(
        id: UUID,
        response: TerminalScrollResponse?,
        succeeded: Bool
    ) {
        guard case .scroll(var transaction) = phase, transaction.id == id else { return }
        remoteTask = nil
        guard succeeded, let response else {
            recoverFromLaneFailure()
            return
        }
        transaction.remoteCompleted = true
        transaction.response = response
        phase = .scroll(transaction)
        reconcileScrollIfReady(id: id)
    }

    private func reconcileScrollIfReady(id: UUID) {
        guard case .scroll(var transaction) = phase,
              transaction.id == id,
              transaction.localApplied,
              transaction.remoteCompleted,
              let response = transaction.response else { return }
        if let renderGrid = response.preparedRenderGrid {
            let followingScrollRuns: [MobileTerminalScrollRun]
            if case .scroll(let queuedScroll) = intents.first,
               !queuedScroll.localReceipts.isEmpty {
                followingScrollRuns = queuedScroll.runs
            } else {
                followingScrollRuns = []
            }
            transaction.awaitingAuthoritative = true
            phase = .scroll(transaction)
            guard deliverAuthoritative(
                renderGrid,
                response.interactionEpoch,
                response.clientRevision,
                followingScrollRuns
            ) else {
                recoverFromLaneFailure()
                return
            }
            return
        }
        guard completeGridlessAuthoritative(response.renderRevision) else {
            recoverFromLaneFailure()
            return
        }
        finishScroll(transaction)
    }

    func authoritativeDidApply(interactionEpoch: UInt64, clientRevision: UInt64) {
        guard case .scroll(let transaction) = phase,
              transaction.awaitingAuthoritative,
              transaction.request.interactionEpoch == interactionEpoch,
              transaction.request.clientRevision == clientRevision else { return }
        finishScroll(transaction)
    }

    func authoritativeReconciliationWasSuperseded(
        _ supersession: TerminalScrollReconciliationSupersession
    ) {
        let reconciliation = supersession.reconciliation
        guard case .scroll(let transaction) = phase,
              transaction.awaitingAuthoritative,
              transaction.request.interactionEpoch == reconciliation.interactionEpoch,
              transaction.request.clientRevision == reconciliation.clientRevision else { return }
        latestReconciledRevision = transaction.request.clientRevision
        cancelPhaseTasks()
        phase = .idle
        reconciliationDidComplete()
        startNextIntentIfIdle()
    }

    private func finishScroll(_ transaction: ScrollTransaction) {
        latestReconciledRevision = transaction.request.clientRevision
        cancelPhaseTasks()
        phase = .idle
        reconciliationDidComplete()
        startNextIntentIfIdle()
    }

    private func scrollDeadlineDidFire(id: UUID) {
        guard case .scroll(let transaction) = phase, transaction.id == id else { return }
        recoverFromLaneFailure()
    }

    private func startClick(col: Int, row: Int) {
        let transaction = ClickTransaction(id: UUID(), col: col, row: row, epoch: nil)
        let receipt = enqueueBarrier()
        phase = .clickBarrier(transaction)
        barrierTask = Task { @MainActor [weak self] in
            let applied = await receipt.value
            guard !Task.isCancelled else { return }
            self?.clickBarrierDidComplete(id: transaction.id, applied: applied)
        }
    }

    private func clickBarrierDidComplete(id: UUID, applied: Bool) {
        guard case .clickBarrier(var transaction) = phase, transaction.id == id else { return }
        barrierTask = nil
        guard applied else {
            recoverFromLaneFailure()
            return
        }
        transaction.epoch = advanceToNextEpoch()
        phase = .clickSend(transaction)
        remoteTask = Task { @MainActor [weak self] in
            guard let self, let epoch = transaction.epoch else { return }
            let succeeded = await self.sendClick(
                self.surfaceID,
                epoch,
                transaction.col,
                transaction.row
            )
            guard !Task.isCancelled else { return }
            self.clickDidComplete(id: transaction.id, succeeded: succeeded)
        }
    }

    private func clickDidComplete(id: UUID, succeeded: Bool) {
        guard case .clickSend(let transaction) = phase, transaction.id == id else { return }
        remoteTask = nil
        guard succeeded else {
            recoverFromLaneFailure()
            return
        }
        phase = .idle
        startNextIntentIfIdle()
    }

}
