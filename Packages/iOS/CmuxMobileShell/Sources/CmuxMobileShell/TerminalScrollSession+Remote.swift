import Foundation

extension TerminalScrollSession {
    func startNextIntentIfIdle() {
        guard case .idle = phase, let intent = removeNextIntent() else { return }
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
        lastDirectionLines = first.lines
        lastCol = first.col
        lastRow = first.row
        var nextRevision = latestClientRevision &+ UInt64(scroll.submissionCount)
        if nextRevision == 0 { nextRevision = 1 }
        var request = TerminalScrollRequest(
            surfaceID: surfaceID,
            interactionEpoch: interactionEpoch,
            clientRevision: nextRevision,
            lines: first.lines,
            col: first.col,
            row: first.row,
            prefetchWindow: prefetchWindow(for: first.lines)
        )
        for run in scroll.runs.dropFirst() {
            let appended = request.append(TerminalScrollRequest(
                surfaceID: surfaceID,
                interactionEpoch: interactionEpoch,
                clientRevision: nextRevision,
                lines: run.lines,
                col: run.col,
                row: run.row,
                prefetchWindow: prefetchWindow(for: run.lines)
            ))
            guard appended else {
                recoverFromLaneFailure()
                return
            }
            lastDirectionLines = run.lines
            lastCol = run.col
            lastRow = run.row
        }
        if request.prefetchWindow == nil {
            request.prefetchWindow = scroll.inheritedPrefetchWindow
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
        let plannedRequests = request.plannedRPCRequests(
            supportsOrderedRuns: supportsOrderedRemoteRuns()
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
            for plannedRequest in plannedRequests {
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
            guard !Task.isCancelled else { return }
            self.scrollRemoteDidComplete(id: id, response: response, succeeded: true)
        }
        deadlineTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.interactionDeadline(Self.interactionPlanDeadlineDuration(
                plannedRequestCount: plannedRequests.count
            ))
            guard !Task.isCancelled else { return }
            self.scrollDeadlineDidFire(id: id)
        }
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
        if intents.first?.isOptimisticallyAppliedScroll == true {
            if let inheritedWindow = transaction.request.prefetchWindow {
                intents.mutateFirst { intent in
                    guard case .scroll(var scroll) = intent,
                          scroll.inheritedPrefetchWindow == nil else { return }
                    scroll.inheritedPrefetchWindow = inheritedWindow
                    intent = .scroll(scroll)
                }
            }
            cancelPhaseTasks()
            phase = .idle
            startNextIntentIfIdle()
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
        if intents.first?.isOptimisticallyAppliedScroll == true {
            cancelPhaseTasks()
            phase = .idle
            startNextIntentIfIdle()
            return
        }
        if let frame = response.renderGrid {
            transaction.awaitingAuthoritative = true
            phase = .scroll(transaction)
            guard deliverAuthoritative(
                frame,
                response.interactionEpoch,
                response.clientRevision
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
        if supersession.reason != .optimisticScroll {
            reconciliationDidComplete()
        }
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

    private func startInput(_ input: InputTransaction) {
        prepareInput()
        var transaction = input
        transaction.epoch = advanceToNextEpoch()
        guard input.snapGeneration > consumedBottomSnapGeneration else {
            startInputSend(transaction)
            return
        }
        lastDirectionLines = 1
        let receipt = enqueueScrollToBottom()
        phase = .inputSnap(transaction)
        inputTask = Task { @MainActor [weak self] in
            let applied = await receipt.value
            guard !Task.isCancelled else { return }
            self?.inputSnapDidComplete(
                id: transaction.id,
                generation: transaction.snapGeneration,
                applied: applied
            )
        }
    }

    private func inputSnapDidComplete(id: UUID, generation: UInt64, applied: Bool) {
        guard case .inputSnap(let transaction) = phase, transaction.id == id else { return }
        inputTask = nil
        if applied {
            consumedBottomSnapGeneration = max(consumedBottomSnapGeneration, generation)
        }
        startInputSend(transaction)
    }

    private func startInputSend(_ transaction: InputTransaction) {
        guard let epoch = transaction.epoch else {
            transaction.receipt.resolve(false)
            phase = .idle
            startNextIntentIfIdle()
            return
        }
        if case .fence = transaction.input {
            transaction.receipt.resolve(true)
            phase = .idle
            startNextIntentIfIdle()
            return
        }
        phase = .inputSend(transaction)
        inputTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let succeeded = await self.sendInput(self.surfaceID, epoch, transaction.input)
            guard !Task.isCancelled else { return }
            self.inputDidComplete(id: transaction.id, succeeded: succeeded)
        }
    }

    private func inputDidComplete(id: UUID, succeeded: Bool) {
        guard case .inputSend(let transaction) = phase, transaction.id == id else { return }
        inputTask = nil
        transaction.receipt.resolve(succeeded)
        phase = .idle
        startNextIntentIfIdle()
    }
}
