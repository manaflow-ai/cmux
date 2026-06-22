import Foundation

extension AgentChatTranscriptService {
    typealias PendingTitleChange = (change: GhosttyTitleChange, titleKey: String)
    typealias ClaudeTranscriptResolutionKey = (
        targetSessionID: String,
        workingDirectory: String,
        claimedSessionIDs: Set<String>,
        titleKey: String?,
        forceScan: Bool
    )

    func scheduleTitleDetectedAdoption(_ change: GhosttyTitleChange) {
        let surfaceID = change.surfaceId.uuidString
        guard let titleKey = Self.claudeTitleDetectionKey(change.title) else {
            // A superseding non-Claude title invalidates queued/in-flight
            // adoption, but keeps the negative scan throttle in place.
            pendingTitleChanges.removeValue(forKey: surfaceID)
            deliveredTitleKeys.removeValue(forKey: surfaceID)
            cancelTranscriptResolution(surfaceID: surfaceID, resetThrottle: false)
            retireProvisionalClaudeSession(surfaceID: surfaceID, resetThrottle: false)
            return
        }
        if pendingTitleChanges[surfaceID]?.titleKey == titleKey {
            return
        }
        if pendingTitleChanges[surfaceID] == nil,
           deliveredTitleKeys[surfaceID] == titleKey,
           registry.liveSession(surfaceID: surfaceID)?.transcriptPath != nil {
            return
        }

        pendingTitleChanges[surfaceID] = (change: change, titleKey: titleKey)
        titleChangeCoalescer.signal { [weak self] in
            self?.flushTitleDetectedAdoptions()
        }
    }

    func flushTitleDetectedAdoptions() {
        guard !pendingTitleChanges.isEmpty else {
            return
        }
        let pendingBySurface = pendingTitleChanges
        pendingTitleChanges.removeAll(keepingCapacity: true)
        for (surfaceID, pending) in pendingBySurface {
            if titleAdoptionHandler?(pending.change) == true,
               registry.liveSession(surfaceID: surfaceID)?.transcriptPath != nil {
                deliveredTitleKeys[surfaceID] = pending.titleKey
            }
        }
    }

    func clearTitleDetectionState(
        surfaceID: String,
        releaseTranscriptClaims: Bool = false
    ) {
        pendingTitleChanges.removeValue(forKey: surfaceID)
        deliveredTitleKeys.removeValue(forKey: surfaceID)
        cancelTranscriptResolution(surfaceID: surfaceID)
        if releaseTranscriptClaims {
            claimedDetectedTranscriptSessionIDsBySurfaceID.removeValue(forKey: surfaceID)
        }
    }

    func cancelTranscriptResolution(surfaceID: String, resetThrottle: Bool = true) {
        transcriptResolutionTasks[surfaceID]?.cancel()
        transcriptResolutionTasks[surfaceID] = nil
        transcriptResolutionKeys.removeValue(forKey: surfaceID)
        transcriptResolutionForcedRetryCounts.removeValue(forKey: surfaceID)
        if resetThrottle {
            detectionScanAt.removeValue(forKey: surfaceID)
            detectionScanContextKeys.removeValue(forKey: surfaceID)
        }
    }

    func scheduleClaudeTranscriptResolution(
        workspaceID: String,
        workingDirectory: String,
        surfaceID: String,
        targetSessionID: String,
        excludingSessionID: String?,
        titleHint: String?,
        forceScan: Bool,
        throttleForcedScan: Bool = false
    ) {
        let now = Date()
        var claimed = registry.claimedSessionIDs()
            .union(activeClaimedDetectedTranscriptSessionIDs(excludingSurfaceID: surfaceID))
        if let excludingSessionID {
            claimed.remove(excludingSessionID)
        }
        let titleKey = Self.specificClaudeTitleKey(titleHint)
        let key: ClaudeTranscriptResolutionKey = (
            targetSessionID: targetSessionID,
            workingDirectory: workingDirectory,
            claimedSessionIDs: claimed,
            titleKey: titleKey,
            forceScan: forceScan
        )
        let scanTitleKey = titleKey ?? "generic"
        let scanContextKey = "\(targetSessionID)\u{0}\(workingDirectory)\u{0}\(scanTitleKey)"
        let shouldThrottleSameContext = !forceScan || throttleForcedScan
        if shouldThrottleSameContext,
           let lastScan = detectionScanAt[surfaceID],
           detectionScanContextKeys[surfaceID] == scanContextKey,
           now.timeIntervalSince(lastScan) < Self.detectionScanThrottle {
            return
        }
        if let currentKey = transcriptResolutionKeys[surfaceID],
           currentKey == key {
            return
        }

        detectionScanAt[surfaceID] = now
        detectionScanContextKeys[surfaceID] = scanContextKey
        transcriptResolutionKeys[surfaceID] = key
        if !forceScan {
            transcriptResolutionForcedRetryCounts.removeValue(forKey: surfaceID)
        }
        transcriptResolutionTasks[surfaceID]?.cancel()
        let resolver = self.resolver
        #if compiler(>=6.2)
        let resolveOperation: @concurrent @Sendable () async -> (sessionID: String, path: String)? = {
            [resolver, workingDirectory, claimed, titleHint] in
            resolver.newestClaudeTranscript(
                workingDirectory: workingDirectory,
                excludingSessionIDs: claimed,
                titleHint: titleHint
            )
        }
        #else
        let resolveOperation: @Sendable () async -> (sessionID: String, path: String)? = {
            [resolver, workingDirectory, claimed, titleHint] in
            resolver.newestClaudeTranscript(
                workingDirectory: workingDirectory,
                excludingSessionIDs: claimed,
                titleHint: titleHint
            )
        }
        #endif
        let scanTask = Task.detached(priority: .utility, operation: resolveOperation)
        transcriptResolutionTasks[surfaceID] = Task { @MainActor [
            weak self,
            scanTask,
            key,
            workspaceID,
            workingDirectory,
            surfaceID,
            titleHint
        ] in
            let resolved = await withTaskCancellationHandler {
                await scanTask.value
            } onCancel: {
                scanTask.cancel()
            }
            guard !Task.isCancelled else { return }
            self?.applyClaudeTranscriptResolution(
                resolved,
                key: key,
                workspaceID: workspaceID,
                workingDirectory: workingDirectory,
                surfaceID: surfaceID,
                titleHint: titleHint
            )
        }
    }

    func applyClaudeTranscriptResolution(
        _ resolved: (sessionID: String, path: String)?,
        key: ClaudeTranscriptResolutionKey,
        workspaceID: String,
        workingDirectory: String,
        surfaceID: String,
        titleHint: String?
    ) {
        guard let currentKey = transcriptResolutionKeys[surfaceID],
              currentKey == key else {
            return
        }
        transcriptResolutionTasks[surfaceID] = nil
        transcriptResolutionKeys[surfaceID] = nil

        guard let resolved else { return }
        guard let target = registry.record(sessionID: key.targetSessionID),
              target.surfaceID == surfaceID,
              target.workspaceID == workspaceID,
              target.workingDirectory == workingDirectory,
              target.state != .ended,
              target.transcriptPath == nil else {
            return
        }
        if !Self.isProvisionalClaudeSessionID(target.sessionID),
           resolved.sessionID != target.sessionID {
            return
        }
        guard !activeClaimedDetectedTranscriptSessionIDs(excludingSurfaceID: surfaceID).contains(resolved.sessionID) else {
            scheduleForcedClaudeTranscriptRetry(
                workspaceID: workspaceID,
                workingDirectory: workingDirectory,
                surfaceID: surfaceID,
                targetSessionID: key.targetSessionID,
                excludingSessionID: key.targetSessionID,
                titleHint: titleHint
            )
            return
        }
        if let claimed = registry.record(sessionID: resolved.sessionID),
           claimed.surfaceID != nil,
           claimed.surfaceID != surfaceID {
            scheduleForcedClaudeTranscriptRetry(
                workspaceID: workspaceID,
                workingDirectory: workingDirectory,
                surfaceID: surfaceID,
                targetSessionID: key.targetSessionID,
                excludingSessionID: key.targetSessionID,
                titleHint: titleHint
            )
            return
        }

        detectionScanAt.removeValue(forKey: surfaceID)
        detectionScanContextKeys.removeValue(forKey: surfaceID)
        registry.update(sessionID: target.sessionID) { record in
            record.workspaceID = workspaceID
            record.surfaceID = surfaceID
            record.workingDirectory = workingDirectory
            record.transcriptPath = resolved.path
        }
        claimDetectedTranscriptSessionID(resolved.sessionID, surfaceID: surfaceID)
        transcriptResolutionForcedRetryCounts.removeValue(forKey: surfaceID)
    }

    func scheduleForcedClaudeTranscriptRetry(
        workspaceID: String,
        workingDirectory: String,
        surfaceID: String,
        targetSessionID: String,
        excludingSessionID: String?,
        titleHint: String?
    ) {
        let retryCount = transcriptResolutionForcedRetryCounts[surfaceID, default: 0]
        guard retryCount < Self.maxTranscriptResolutionForcedRetries else {
            return
        }
        transcriptResolutionForcedRetryCounts[surfaceID] = retryCount + 1
        scheduleClaudeTranscriptResolution(
            workspaceID: workspaceID,
            workingDirectory: workingDirectory,
            surfaceID: surfaceID,
            targetSessionID: targetSessionID,
            excludingSessionID: excludingSessionID,
            titleHint: titleHint,
            forceScan: true
        )
    }

    func activeClaimedDetectedTranscriptSessionIDs(excludingSurfaceID surfaceID: String) -> Set<String> {
        var claimed = Set<String>()
        for (claimedSurfaceID, sessionIDs) in claimedDetectedTranscriptSessionIDsBySurfaceID
        where claimedSurfaceID != surfaceID {
            claimed.formUnion(sessionIDs)
        }
        return claimed
    }

    func newestClaudeTranscript(
        workingDirectory: String,
        surfaceID: String,
        excludingSessionID: String?,
        titleHint: String?,
        forceScan: Bool
    ) -> (sessionID: String, path: String)? {
        let now = Date()
        if !forceScan,
           let lastScan = detectionScanAt[surfaceID],
           now.timeIntervalSince(lastScan) < Self.detectionScanThrottle {
            return nil
        }
        detectionScanAt[surfaceID] = now
        var claimed = registry.claimedSessionIDs()
            .union(activeClaimedDetectedTranscriptSessionIDs(excludingSurfaceID: surfaceID))
        if let excludingSessionID {
            claimed.remove(excludingSessionID)
        }
        return resolver.newestClaudeTranscript(
            workingDirectory: workingDirectory,
            excludingSessionIDs: claimed,
            titleHint: titleHint
        )
    }

    func claimDetectedTranscriptSessionID(_ sessionID: String, surfaceID: String) {
        claimedDetectedTranscriptSessionIDsBySurfaceID[surfaceID, default: []].insert(sessionID)
    }
}
