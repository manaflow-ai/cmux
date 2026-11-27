import Foundation

extension WorkspaceTerminalFontSizeCoordinator {
    final class TransferResourceState {
        private(set) var outstandingRequestCount = 0
        private(set) var firstRequest: TransferRequestRecord?
        private(set) var lastRequest: TransferRequestRecord?
        private var requestsByToken:
            [UUID: TransferRequestRecord] = [:]
        private var obligationsByPanelId: [UUID: TransferObligation] = [:]
        private var stagedObligationPanelIds: Set<UUID> = []

        func appendRequest(_ record: TransferRequestRecord) {
            precondition(
                requestsByToken[record.request.token] == nil
            )
            outstandingRequestCount += 1
            requestsByToken[record.request.token] = record
            record.previous = lastRequest
            lastRequest?.next = record
            if firstRequest == nil {
                firstRequest = record
            }
            lastRequest = record
        }

        private func indexNextRequest(
            for obligation: TransferObligation
        ) {
            guard let nextRequest = obligation.nextRequest else {
                return
            }
            nextRequest.obligationStartPanelIds.insert(
                obligation.panelId
            )
        }

        private func indexThroughRequest(
            for obligation: TransferObligation
        ) {
            obligation.throughRequest
                .obligationEndPanelIds.insert(
                    obligation.panelId
                )
        }

        private func unindexNextRequest(
            for obligation: TransferObligation
        ) {
            guard let nextRequest = obligation.nextRequest else {
                return
            }
            nextRequest.obligationStartPanelIds.remove(
                obligation.panelId
            )
        }

        private func unindexThroughRequest(
            for obligation: TransferObligation
        ) {
            obligation.throughRequest
                .obligationEndPanelIds.remove(
                    obligation.panelId
                )
        }

        private func addStagedInterval(
            for obligation: TransferObligation
        ) {
            guard let nextRequest = obligation.nextRequest else {
                preconditionFailure(
                    "Staged transfer requires a request interval"
                )
            }
            let start = nextRequest.request.sequence
            let end = obligation.throughRequest.request.sequence
            precondition(start <= end)
            nextRequest.stagedIntervalStartCount += 1
            obligation.throughRequest
                .stagedIntervalEndCount += 1
        }

        private func removeStagedInterval(
            for obligation: TransferObligation
        ) {
            guard let nextRequest = obligation.nextRequest else {
                preconditionFailure(
                    "Staged transfer requires a request interval"
                )
            }
            precondition(
                nextRequest.stagedIntervalStartCount > 0
            )
            precondition(
                obligation.throughRequest
                    .stagedIntervalEndCount > 0
            )
            nextRequest.stagedIntervalStartCount -= 1
            obligation.throughRequest
                .stagedIntervalEndCount -= 1
        }

        /// Adjusts every affected interval once for a bulk cancellation.
        /// Subsequent per-request unlinks therefore remain constant-time.
        func prepareToRetireRequests(
            _ tokens: Set<UUID>
        ) -> ObligationAdjustment {
            guard !tokens.isEmpty else {
                return ObligationAdjustment(
                    obligationsToRemove: [],
                    obligationsToRepair: []
                )
            }

            var affectedPanelIds: Set<UUID> = []
            for token in tokens {
                guard let record = requestsByToken[token] else {
                    preconditionFailure(
                        "Missing transfer request record"
                    )
                }
                affectedPanelIds.formUnion(
                    record.obligationStartPanelIds
                )
                affectedPanelIds.formUnion(
                    record.obligationEndPanelIds
                )
            }
            guard !affectedPanelIds.isEmpty else {
                return ObligationAdjustment(
                    obligationsToRemove: [],
                    obligationsToRepair: []
                )
            }

            var records: [TransferRequestRecord] = []
            var record = firstRequest
            while let current = record {
                records.append(current)
                record = current.next
            }
            var nextSurvivingByToken:
                [UUID: TransferRequestRecord] = [:]
            var nextSurviving: TransferRequestRecord?
            for current in records.reversed() {
                if !tokens.contains(current.request.token) {
                    nextSurviving = current
                }
                if let nextSurviving {
                    nextSurvivingByToken[
                        current.request.token
                    ] = nextSurviving
                }
            }
            var previousSurvivingByToken:
                [UUID: TransferRequestRecord] = [:]
            var previousSurviving: TransferRequestRecord?
            for current in records {
                if !tokens.contains(current.request.token) {
                    previousSurviving = current
                }
                if let previousSurviving {
                    previousSurvivingByToken[
                        current.request.token
                    ] = previousSurviving
                }
            }

            var obligationsToRemove: [TransferObligation] = []
            var obligationsToRepair: [TransferObligation] = []
            for panelId in affectedPanelIds {
                guard let obligation =
                        obligationsByPanelId[panelId],
                      let currentNext =
                        obligation.nextRequest else {
                    preconditionFailure(
                        "Missing indexed transfer obligation"
                    )
                }
                let currentThrough = obligation.throughRequest
                let next =
                    tokens.contains(currentNext.request.token)
                    ? nextSurvivingByToken[
                        currentNext.request.token
                    ]
                    : currentNext
                let through =
                    tokens.contains(
                        currentThrough.request.token
                    )
                    ? previousSurvivingByToken[
                        currentThrough.request.token
                    ]
                    : currentThrough
                guard let next, let through,
                      next.request.sequence
                        <= through.request.sequence else {
                    obligationsToRemove.append(obligation)
                    continue
                }

                let nextChanged = next !== currentNext
                let throughChanged =
                    through !== currentThrough
                guard nextChanged || throughChanged else {
                    continue
                }
                let isStaged =
                    stagedObligationPanelIds
                        .contains(obligation.panelId)
                if isStaged {
                    removeStagedInterval(for: obligation)
                }
                if nextChanged {
                    unindexNextRequest(for: obligation)
                    obligation.nextRequest = next
                    indexNextRequest(for: obligation)
                    obligationsToRepair.append(obligation)
                }
                if throughChanged {
                    unindexThroughRequest(for: obligation)
                    obligation.throughRequest = through
                    indexThroughRequest(for: obligation)
                }
                if isStaged {
                    addStagedInterval(for: obligation)
                }
            }
            return ObligationAdjustment(
                obligationsToRemove: obligationsToRemove,
                obligationsToRepair: obligationsToRepair
            )
        }

        func retireRequest(token: UUID) -> RequestRetirement {
            precondition(outstandingRequestCount > 0)
            guard let record =
                    requestsByToken.removeValue(
                        forKey: token
                    ) else {
                preconditionFailure("Missing transfer request record")
            }

            let previous = record.previous
            let next = record.next
            var obligationsToRemove: [TransferObligation] = []
            var obligationsToRepair: [TransferObligation] = []
            let nextPanelIds =
                record.obligationStartPanelIds
            record.obligationStartPanelIds.removeAll(
                keepingCapacity: false
            )
            let throughPanelIds =
                record.obligationEndPanelIds
            record.obligationEndPanelIds.removeAll(
                keepingCapacity: false
            )
            let affectedPanelIds =
                nextPanelIds.union(throughPanelIds)
            for panelId in affectedPanelIds {
                guard let obligation =
                        obligationsByPanelId[panelId] else {
                    preconditionFailure(
                        "Missing indexed transfer obligation"
                    )
                }
                let beginsWithRecord =
                    obligation.nextRequest === record
                let endsWithRecord =
                    obligation.throughRequest === record
                precondition(
                    beginsWithRecord || endsWithRecord
                )
                let isStaged =
                    stagedObligationPanelIds
                        .contains(obligation.panelId)
                if isStaged {
                    removeStagedInterval(for: obligation)
                }
                switch (beginsWithRecord, endsWithRecord) {
                case (true, true):
                    obligation.nextRequest = nil
                    stagedObligationPanelIds.remove(
                        obligation.panelId
                    )
                    obligationsToRemove.append(obligation)
                case (true, false):
                    guard let next else {
                        preconditionFailure(
                            "Transfer interval lost its next request"
                        )
                    }
                    obligation.nextRequest = next
                    indexNextRequest(for: obligation)
                    obligationsToRepair.append(obligation)
                case (false, true):
                    guard let previous else {
                        preconditionFailure(
                            "Transfer interval lost its final request"
                        )
                    }
                    obligation.throughRequest = previous
                    indexThroughRequest(for: obligation)
                case (false, false):
                    preconditionFailure(
                        "Transfer endpoint index drifted"
                    )
                }
                if isStaged,
                   obligation.nextRequest != nil {
                    addStagedInterval(for: obligation)
                }
            }

            precondition(record.stagedIntervalStartCount == 0)
            precondition(record.stagedIntervalEndCount == 0)
            previous?.next = next
            next?.previous = previous
            if firstRequest === record {
                firstRequest = next
            }
            if lastRequest === record {
                lastRequest = previous
            }
            record.previous = nil
            record.next = nil
            outstandingRequestCount -= 1
            precondition(
                outstandingRequestCount == requestsByToken.count
            )
            let resourceBecameIdle =
                outstandingRequestCount == 0
            if resourceBecameIdle {
                obligationsToRemove =
                    Array(obligationsByPanelId.values)
                obligationsToRepair.removeAll(
                    keepingCapacity: false
                )
            }
            return RequestRetirement(
                resourceBecameIdle: resourceBecameIdle,
                obligationsToRemove: obligationsToRemove,
                obligationsToRepair: obligationsToRepair
            )
        }

        func register(
            panel: TerminalPanel
        ) -> (obligation: TransferObligation, isNew: Bool)? {
            guard let firstRequest, let lastRequest else { return nil }
            if let existing = obligationsByPanelId[panel.id] {
                guard existing.throughRequest !== lastRequest else {
                    return (existing, false)
                }
                let isStaged =
                    stagedObligationPanelIds
                        .contains(existing.panelId)
                if isStaged {
                    removeStagedInterval(for: existing)
                }
                unindexThroughRequest(for: existing)
                existing.throughRequest = lastRequest
                indexThroughRequest(for: existing)
                if isStaged {
                    addStagedInterval(for: existing)
                }
                return (existing, false)
            }
            let obligation = TransferObligation(
                panel: panel,
                resourceState: self,
                nextRequest: firstRequest,
                throughRequest: lastRequest
            )
            obligationsByPanelId[panel.id] = obligation
            indexNextRequest(for: obligation)
            indexThroughRequest(for: obligation)
            return (obligation, true)
        }

        func markStaged(_ obligation: TransferObligation) {
            guard obligationsByPanelId[obligation.panelId]
                    === obligation,
                  stagedObligationPanelIds.insert(
                    obligation.panelId
                  ).inserted else {
                return
            }
            addStagedInterval(for: obligation)
        }

        func advance(
            _ obligation: TransferObligation,
            past record: TransferRequestRecord
        ) -> Bool {
            precondition(
                obligationsByPanelId[obligation.panelId]
                    === obligation
            )
            precondition(obligation.nextRequest === record)
            if obligation.throughRequest === record {
                return true
            }
            let isStaged =
                stagedObligationPanelIds
                    .contains(obligation.panelId)
            if isStaged {
                removeStagedInterval(for: obligation)
            }
            unindexNextRequest(for: obligation)
            guard let next = record.next else {
                preconditionFailure(
                    "Transfer interval lost its next request"
                )
            }
            obligation.nextRequest = next
            indexNextRequest(for: obligation)
            if isStaged {
                addStagedInterval(for: obligation)
            }
            return false
        }

        func remove(_ obligation: TransferObligation) {
            guard obligationsByPanelId.removeValue(
                forKey: obligation.panelId
            ) === obligation else {
                return
            }
            if stagedObligationPanelIds.remove(
                obligation.panelId
            ) != nil {
                removeStagedInterval(for: obligation)
            }
            unindexNextRequest(for: obligation)
            unindexThroughRequest(for: obligation)
            obligation.resourceState = nil
            obligation.nextRequest = nil
        }

        /// Sweeps the bounded request chain once, independent of the number
        /// of overlapping staged panel transfers.
        func collectStagedRequestTokens(
            into tokens: inout Set<UUID>
        ) {
            guard !stagedObligationPanelIds.isEmpty else {
                return
            }
            var activeIntervalCount = 0
            var record = firstRequest
            while let current = record {
                activeIntervalCount +=
                    current.stagedIntervalStartCount
                if activeIntervalCount > 0 {
                    tokens.insert(current.request.token)
                }
                activeIntervalCount -=
                    current.stagedIntervalEndCount
                precondition(activeIntervalCount >= 0)
                record = current.next
            }
            precondition(activeIntervalCount == 0)
        }

        func snapshotProjectionRequests(
            for panelIds: Set<UUID>
        ) -> [UUID: [PendingRequest]] {
            var result: [UUID: [PendingRequest]] = [:]
            for (panelId, obligation) in obligationsByPanelId
            where panelIds.contains(panelId) {
                guard var record = obligation.nextRequest else {
                    continue
                }
                while true {
                    result[panelId, default: []].append(
                        record.request
                    )
                    if record === obligation.throughRequest {
                        break
                    }
                    guard let next = record.next else {
                        preconditionFailure(
                            "Transfer projection interval lost its final request"
                        )
                    }
                    record = next
                }
            }
            return result
        }
    }
}
