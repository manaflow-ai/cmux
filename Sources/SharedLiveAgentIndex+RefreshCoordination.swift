import Foundation

extension SharedLiveAgentIndex {
    func requestRefresh(
        freshness: RefreshFreshness,
        publication: RefreshPublication,
        validating panelKey: PanelKey?,
        cachedResultToValidate: LoadResult? = nil
    ) -> Task<LoadResult?, Never> {
        requestRefreshDetails(
            freshness: freshness,
            publication: publication,
            validating: panelKey,
            cachedResultToValidate: cachedResultToValidate
        ).task
    }

    func requestRefreshDetails(
        freshness: RefreshFreshness,
        publication: RefreshPublication,
        validating panelKey: PanelKey?,
        cachedResultToValidate: LoadResult? = nil
    ) -> RefreshRequest {
        if let refreshTailID,
           var generation = refreshGenerationsByID[refreshTailID],
           let task = refreshTasksByID[refreshTailID],
           (freshness == .joinCurrentGeneration && generation.phase != .timedOut)
               || generation.phase == .queued {
            if cachedResultToValidate == nil {
                generation.cachedResultToValidate = nil
                generation.cachedResultRevision = nil
            }
            generation.publication.include(publication)
            if let panelKey {
                generation.validationPanelsByPanelID[panelKey.panelId] = panelKey
                pendingForkValidationGenerationByPanelID[panelKey.panelId] = generation.id
            }
            refreshGenerationsByID[refreshTailID] = generation
            let processMetadataCapture = processMetadataCaptureByGenerationID[refreshTailID]
                ?? unavailableProcessMetadataCapture()
            return RefreshRequest(
                generationID: refreshTailID,
                task: task,
                processMetadataCapture: processMetadataCapture
            )
        }

        // Timed-out generations keep their physical loader until it returns. Count them here
        // because that synchronous work cannot be cancelled, so replacements could grow unbounded.
        guard refreshGenerationsByID.count < Self.maximumConcurrentPhysicalLoads else {
            return RefreshRequest(
                generationID: nil,
                task: Task { nil },
                processMetadataCapture: unavailableProcessMetadataCapture()
            )
        }

        let predecessor = refreshTailID.flatMap { refreshTasksByID[$0] }
        let generationID = UUID()
        nextRefreshOrdinal &+= 1
        var validationPanelsByPanelID: [UUID: PanelKey] = [:]
        if let panelKey {
            validationPanelsByPanelID[panelKey.panelId] = panelKey
            pendingForkValidationGenerationByPanelID[panelKey.panelId] = generationID
        }

        var generation = RefreshGeneration(
            id: generationID,
            ordinal: nextRefreshOrdinal,
            phase: .queued,
            publication: publication,
            validationPanelsByPanelID: validationPanelsByPanelID,
            cachedResultToValidate: cachedResultToValidate
        )
        if cachedResultToValidate != nil {
            generation.cachedResultRevision = resumeAuthorityRevision
        }
        refreshGenerationsByID[generationID] = generation
        let processMetadataCapture = SharedLiveAgentIndexProcessMetadataBoundary()
        processMetadataCaptureByGenerationID[generationID] = processMetadataCapture
        let task = Task { @MainActor [weak self] () -> LoadResult? in
            guard let self else { return nil }
            return await self.consumeRefreshOutcome(generationID: generationID)
        }
        refreshTasksByID[generationID] = task
        refreshTailID = generationID

        let generationTimeoutWaiter = self.generationTimeoutWaiter
        refreshTimeoutTasksByID[generationID] = Task { @MainActor [weak self] in
            let didTimeOut = await generationTimeoutWaiter()
            guard didTimeOut, !Task.isCancelled else { return }
            self?.handleRefreshTimeout(generationID: generationID)
        }

        let workTask = Task { @MainActor [weak self] in
            _ = await predecessor?.value
            guard let self, !Task.isCancelled else { return }
            guard var generation = self.refreshGenerationsByID[generationID] else { return }
            assert(self.capturingGenerationIDs.count < Self.maximumConcurrentPhysicalLoads)
            generation.phase = .capturing
            self.refreshGenerationsByID[generationID] = generation
            self.capturingGenerationIDs.insert(generationID)

            let cachedResult = generation.cachedResultToValidate
            let cachedResultMatches = await self.cachedResultMatchesCurrentProcessScope(cachedResult)
            guard let currentGeneration = self.refreshGenerationsByID[generationID] else { return }
            guard currentGeneration.phase == .capturing else {
                self.finishTimedOutRefreshWork(generationID: generationID)
                return
            }
            let ownsCachedAuthority = currentGeneration.cachedResultToValidate != nil
                && currentGeneration.cachedResultRevision == self.resumeAuthorityRevision
                && generation.ordinal >= self.latestCompletedOrdinal
            let reusesCachedResult = cachedResultMatches && ownsCachedAuthority
            if cachedResult != nil,
               !cachedResultMatches,
               ownsCachedAuthority {
                self.invalidateAllCachedResults()
            }
            let result: LoadResult
            if reusesCachedResult, let cachedResult {
                result = cachedResult
            } else {
                result = await self.loadIndex(generationID: generationID)
            }
            self.completeRefresh(
                generationID: generationID,
                result: result,
                preservingPublishedForkValidations: reusesCachedResult
            )
        }
        refreshWorkTasksByID[generationID] = workTask
        return RefreshRequest(
            generationID: generationID,
            task: task,
            processMetadataCapture: processMetadataCapture
        )
    }

    private func unavailableProcessMetadataCapture() -> SharedLiveAgentIndexProcessMetadataBoundary {
        let boundary = SharedLiveAgentIndexProcessMetadataBoundary()
        boundary.resolve(captured: false)
        return boundary
    }

    private func finishTimedOutRefreshWork(generationID: UUID) {
        guard let generation = refreshGenerationsByID[generationID],
              generation.phase == .timedOut else {
            return
        }
        refreshGenerationsByID.removeValue(forKey: generationID)
        refreshTimeoutTasksByID.removeValue(forKey: generationID)?.cancel()
        refreshWorkTasksByID.removeValue(forKey: generationID)
        processMetadataCaptureByGenerationID.removeValue(forKey: generationID)?.resolve(captured: false)
        capturingGenerationIDs.remove(generationID)
        resolvedRefreshOutcomeGenerationIDs.remove(generationID)
        refreshTasksByID.removeValue(forKey: generationID)
        if refreshTailID == generationID {
            refreshTailID = nil
        }
        clearPendingForkValidations(
            validationPanelsByPanelID: generation.validationPanelsByPanelID,
            generationID: generationID
        )
        drainPendingHookStoreChangeIfPossible()
    }

    private func consumeRefreshOutcome(generationID: UUID) async -> LoadResult? {
        if let outcome = refreshOutcomesByID.removeValue(forKey: generationID) {
            return outcome.loadResult
        }
        return await withCheckedContinuation { continuation in
            if let outcome = refreshOutcomesByID.removeValue(forKey: generationID) {
                continuation.resume(returning: outcome.loadResult)
            } else {
                refreshOutcomeContinuationsByID[generationID] = continuation
            }
        }
    }

    private func resolveRefreshOutcome(
        generationID: UUID,
        outcome: RefreshOutcome
    ) {
        guard resolvedRefreshOutcomeGenerationIDs.insert(generationID).inserted else { return }
        if let continuation = refreshOutcomeContinuationsByID.removeValue(forKey: generationID) {
            continuation.resume(returning: outcome.loadResult)
        } else {
            refreshOutcomesByID[generationID] = outcome
        }
    }

    private func handleRefreshTimeout(generationID: UUID) {
        guard var generation = refreshGenerationsByID[generationID] else { return }
        if generation.cachedResultToValidate != nil,
           generation.cachedResultRevision == resumeAuthorityRevision,
           generation.ordinal >= latestCompletedOrdinal {
            invalidateAllCachedResults()
        }
        if generation.phase == .queued {
            refreshGenerationsByID.removeValue(forKey: generationID)
            refreshWorkTasksByID.removeValue(forKey: generationID)?.cancel()
            processMetadataCaptureByGenerationID.removeValue(forKey: generationID)?.resolve(captured: false)
            refreshTimeoutTasksByID.removeValue(forKey: generationID)
            resolveRefreshOutcome(generationID: generationID, outcome: .unavailable)
            resolvedRefreshOutcomeGenerationIDs.remove(generationID)
            refreshTasksByID.removeValue(forKey: generationID)
            if refreshTailID == generationID {
                refreshTailID = nil
            }
            clearPendingForkValidations(
                validationPanelsByPanelID: generation.validationPanelsByPanelID,
                generationID: generationID
            )
            drainPendingHookStoreChangeIfPossible()
            return
        }
        guard generation.phase == .capturing else { return }
        generation.phase = .timedOut
        refreshGenerationsByID[generationID] = generation
        processMetadataCaptureByGenerationID[generationID]?.resolve(captured: false)
        resolveRefreshOutcome(generationID: generationID, outcome: .unavailable)
        clearPendingForkValidations(
            validationPanelsByPanelID: generation.validationPanelsByPanelID,
            generationID: generationID
        )
        drainPendingHookStoreChangeIfPossible()
    }

    private func cachedResultMatchesCurrentProcessScope(
        _ cachedResult: LoadResult?
    ) async -> Bool {
        guard let cachedResult else { return false }
        let processScopeFingerprintProvider = self.processScopeFingerprintProvider
        let currentProcessScopeFingerprint = await Task.detached(priority: .utility) {
            processScopeFingerprintProvider()
        }.value
        return cachedResult.processScopeFingerprint == currentProcessScopeFingerprint
    }

    private func loadIndex(generationID: UUID) async -> LoadResult {
        let indexLoader = self.indexLoader
        let processMetadataCapture = processMetadataCaptureByGenerationID[generationID]
        let result = await Task.detached(priority: .utility) {
            indexLoader {
                processMetadataCapture?.resolve(captured: true)
            }
        }.value
        return result
    }

    private func completeRefresh(
        generationID: UUID,
        result: LoadResult,
        preservingPublishedForkValidations: Bool
    ) {
        guard let generation = refreshGenerationsByID.removeValue(forKey: generationID) else {
            return
        }
        refreshTimeoutTasksByID.removeValue(forKey: generationID)?.cancel()
        refreshWorkTasksByID.removeValue(forKey: generationID)
        processMetadataCaptureByGenerationID.removeValue(forKey: generationID)?.resolve(captured: true)
        capturingGenerationIDs.remove(generationID)
        resolveRefreshOutcome(generationID: generationID, outcome: .result(result))
        resolvedRefreshOutcomeGenerationIDs.remove(generationID)
        refreshTasksByID.removeValue(forKey: generationID)
        if refreshTailID == generationID {
            refreshTailID = nil
        }
        if generation.phase == .timedOut {
            clearPendingForkValidations(
                validationPanelsByPanelID: generation.validationPanelsByPanelID,
                generationID: generationID
            )
        } else if generation.ordinal >= latestCompletedOrdinal {
            latestCompletedOrdinal = generation.ordinal
            latestCompletedLoadResult = result
            latestCompletedAt = dateProvider()

            if generation.publication == .workspace {
                applyReloadedResult(
                    result,
                    validationPanelsByPanelID: generation.validationPanelsByPanelID,
                    generationID: generationID
                )
                NotificationCenter.default.post(name: .sharedLiveAgentIndexDidChange, object: self)
            } else if !preservingPublishedForkValidations {
                invalidatePublishedForkValidations()
            }
        } else {
            clearPendingForkValidations(
                validationPanelsByPanelID: generation.validationPanelsByPanelID,
                generationID: generationID
            )
        }

        drainPendingHookStoreChangeIfPossible()
    }

    private func clearPendingForkValidations(
        validationPanelsByPanelID: [UUID: PanelKey],
        generationID: UUID
    ) {
        for panelID in validationPanelsByPanelID.keys
        where pendingForkValidationGenerationByPanelID[panelID] == generationID {
            pendingForkValidationGenerationByPanelID.removeValue(forKey: panelID)
        }
    }

    func drainPendingHookStoreChangeIfPossible() {
        guard changePending,
              refreshGenerationsByID.count < Self.maximumConcurrentPhysicalLoads else {
            return
        }
        if let refreshTailID,
           refreshGenerationsByID[refreshTailID]?.phase != .timedOut {
            return
        }
        changePending = false
        scheduleHookStoreRefresh()
    }
}
