import Foundation

extension TerminalScrollSession {
    func enqueueRemote(_ interaction: RemoteInteraction) {
        guard remoteInFlight != nil || remotePending.count > 0 else {
            startRemote(interaction)
            return
        }
        if case .scroll(let newerRequest) = interaction.kind {
            var matchedPendingScroll = false
            let appended = remotePending.mutateLast { pending in
                guard case .scroll(var request) = pending.kind,
                      request.interactionEpoch == newerRequest.interactionEpoch else {
                    return false
                }
                matchedPendingScroll = true
                guard request.append(newerRequest) else { return false }
                pending.kind = .scroll(request)
                return true
            }
            if matchedPendingScroll {
                if !appended { recoverFromLaneFailure() }
                return
            }
        }
        if !remotePending.append(interaction) { recoverFromLaneFailure() }
    }

    private func drainRemote() {
        guard remoteInFlight == nil, let next = remotePending.removeFirst() else { return }
        startRemote(next)
    }

    private func startRemote(_ interaction: RemoteInteraction) {
        remoteInFlight = interaction
        remoteTask = Task { @MainActor [weak self] in
            guard let self else { return }
            switch interaction.kind {
            case .scroll(let request):
                let plannedRequests = request.plannedRPCRequests(
                    supportsOrderedRuns: self.supportsOrderedRemoteRuns()
                )
                var response: TerminalScrollResponse?
                for plannedRequest in plannedRequests {
                    guard !Task.isCancelled else { return }
                    guard let plannedResponse = await self.sendRemote(plannedRequest),
                          plannedResponse.accepted,
                          plannedResponse.interactionEpoch == request.interactionEpoch,
                          plannedResponse.clientRevision == request.clientRevision else {
                        self.completeRemote(interaction, response: nil, succeeded: false)
                        return
                    }
                    response = plannedResponse
                }
                self.completeRemote(interaction, response: response, succeeded: true)
            case .click(let epoch, let col, let row, _):
                let succeeded = await self.sendClick(self.surfaceID, epoch, col, row)
                self.completeRemote(interaction, response: nil, succeeded: succeeded)
            }
        }
    }

    private func completeRemote(
        _ interaction: RemoteInteraction,
        response: TerminalScrollResponse?,
        succeeded: Bool
    ) {
        guard remoteInFlight?.id == interaction.id else { return }
        remoteInFlight = nil
        remoteTask = nil
        guard succeeded else {
            recoverFromLaneFailure()
            return
        }

        switch interaction.kind {
        case .scroll(let request):
            recordScrollResponse(response, for: request)
        case .click(_, _, _, let clickID):
            guard pendingClick?.id == clickID else { break }
            pendingClick = nil
            flushPostClickIntents()
        }

        drainRemote()
        reconcileIfReady()
        tryBeginClickBarrier()
    }

    private func recordScrollResponse(
        _ response: TerminalScrollResponse?,
        for request: TerminalScrollRequest
    ) {
        guard request.interactionEpoch == interactionEpoch, let response else { return }
        if response.clientRevision == latestClientRevision {
            if pendingResponse?.renderGrid == nil || response.renderGrid != nil {
                pendingResponse = response
            }
        } else if response.renderGrid != nil {
            remotePending.mutateFirst { pending in
                guard case .scroll(var pendingRequest) = pending.kind,
                      pendingRequest.prefetchWindow == nil else {
                    return
                }
                pendingRequest.prefetchWindow = request.prefetchWindow
                pending.kind = .scroll(pendingRequest)
            }
        }
    }

    func reconcileIfReady() {
        guard let response = pendingResponse,
              response.interactionEpoch == interactionEpoch,
              response.clientRevision == latestClientRevision,
              latestLocallyAppliedRevision >= response.clientRevision else {
            return
        }
        pendingResponse = nil
        if let frame = response.renderGrid {
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
        completeReconciliation(
            interactionEpoch: response.interactionEpoch,
            clientRevision: response.clientRevision
        )
    }

    func tryBeginClickBarrier() {
        guard case .waiting(let id, let col, let row) = pendingClick,
              !isAwaitingAuthoritativeReconciliation,
              localInFlight == nil,
              localPending.count == 0,
              remoteInFlight == nil,
              remotePending.count == 0,
              pendingResponse == nil else {
            return
        }
        let receipt = enqueueBarrier()
        pendingClick = .waitingForBarrier(id: id, col: col, row: row)
        barrierTask = Task { @MainActor [weak self] in
            let applied = await receipt.value
            self?.completeClickBarrier(id: id, col: col, row: row, applied: applied)
        }
    }

    private func completeClickBarrier(
        id: UUID,
        col: Int,
        row: Int,
        applied: Bool
    ) {
        guard case .waitingForBarrier(let pendingID, _, _) = pendingClick,
              pendingID == id else {
            return
        }
        barrierTask = nil
        guard applied else {
            recoverFromLaneFailure()
            return
        }
        advanceForClick(nextEpoch: advanceEpoch())
        pendingClick = .sending(id: id, epoch: interactionEpoch, col: col, row: row)
        enqueueRemote(RemoteInteraction(
            id: UUID(),
            kind: .click(epoch: interactionEpoch, col: col, row: row, clickID: id)
        ))
    }

    private func flushPostClickIntents() {
        while let intent = postClickIntents.removeFirst() {
            submitInCurrentEpoch(lines: intent.lines, col: intent.col, row: intent.row)
        }
        if postClickNeedsSettlement {
            postClickNeedsSettlement = false
            enqueueSettlement()
        }
    }

    func advanceForClick(nextEpoch: UInt64) {
        pendingResponse = nil
        interactionEpoch = nextEpoch
        latestClientRevision = 0
        latestLocallyAppliedRevision = 0
        latestReconciledRevision = 0
        isAwaitingAuthoritativeReconciliation = false
        accumulatedRowsSincePrefetch = 0
        hasPrimedPrefetch = false
    }
}
