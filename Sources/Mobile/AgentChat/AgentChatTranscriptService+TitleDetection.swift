import Foundation

extension AgentChatTranscriptService {
    func scheduleTitleDetectedAdoption(_ change: GhosttyTitleChange) {
        let surfaceID = change.surfaceId.uuidString
        guard let titleKey = Self.claudeTitleDetectionKey(change.title) else {
            clearTitleDetectionState(surfaceID: surfaceID)
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
        transcriptResolutionTasks[surfaceID]?.cancel()
        transcriptResolutionTasks[surfaceID] = nil
        transcriptResolutionKeys.removeValue(forKey: surfaceID)
        transcriptResolutionForcedRetryCounts.removeValue(forKey: surfaceID)
        if releaseTranscriptClaims {
            claimedDetectedTranscriptSessionIDsBySurfaceID.removeValue(forKey: surfaceID)
        }
        detectionScanAt.removeValue(forKey: surfaceID)
    }

    func scheduleClaudeTranscriptResolution(
        workspaceID: String,
        workingDirectory: String,
        surfaceID: String,
        excludingSessionID: String?,
        titleHint: String?,
        forceScan: Bool
    ) {
        let now = Date()
        if !forceScan,
           let lastScan = detectionScanAt[surfaceID],
           now.timeIntervalSince(lastScan) < Self.detectionScanThrottle {
            return
        }

        var claimed = registry.claimedSessionIDs()
            .union(activeClaimedDetectedTranscriptSessionIDs(excludingSurfaceID: surfaceID))
        if let excludingSessionID {
            claimed.remove(excludingSessionID)
        }
        let key: ClaudeTranscriptResolutionKey = (
            workingDirectory: workingDirectory,
            claimedSessionIDs: claimed,
            titleKey: Self.specificClaudeTitleKey(titleHint),
            forceScan: forceScan
        )
        if let currentKey = transcriptResolutionKeys[surfaceID],
           currentKey == key {
            return
        }

        detectionScanAt[surfaceID] = now
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
        guard !activeClaimedDetectedTranscriptSessionIDs(excludingSurfaceID: surfaceID).contains(resolved.sessionID) else {
            scheduleForcedClaudeTranscriptRetry(
                workspaceID: workspaceID,
                workingDirectory: workingDirectory,
                surfaceID: surfaceID,
                excludingSessionID: registry.liveSession(surfaceID: surfaceID)?.sessionID,
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
                excludingSessionID: registry.liveSession(surfaceID: surfaceID)?.sessionID,
                titleHint: titleHint
            )
            return
        }

        detectionScanAt.removeValue(forKey: surfaceID)
        if let bound = registry.liveSession(surfaceID: surfaceID) {
            guard bound.transcriptPath == nil else { return }
            registry.update(sessionID: bound.sessionID) { record in
                record.workspaceID = workspaceID
                record.surfaceID = surfaceID
                record.workingDirectory = workingDirectory
                record.transcriptPath = resolved.path
            }
            claimDetectedTranscriptSessionID(resolved.sessionID, surfaceID: surfaceID)
            transcriptResolutionForcedRetryCounts.removeValue(forKey: surfaceID)
            return
        }

        let adopted = registry.adoptDetectedSession(
            sessionID: resolved.sessionID,
            agentKind: .claude,
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            workingDirectory: workingDirectory,
            transcriptPath: resolved.path,
            at: Date()
        )
        if adopted.surfaceID == surfaceID,
           adopted.transcriptPath == resolved.path {
            claimDetectedTranscriptSessionID(resolved.sessionID, surfaceID: surfaceID)
            transcriptResolutionForcedRetryCounts.removeValue(forKey: surfaceID)
        }
    }

    func scheduleForcedClaudeTranscriptRetry(
        workspaceID: String,
        workingDirectory: String,
        surfaceID: String,
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

    func claimDetectedTranscriptSessionID(_ sessionID: String, surfaceID: String) {
        claimedDetectedTranscriptSessionIDsBySurfaceID[surfaceID, default: []].insert(sessionID)
    }

    func scheduleCodexTranscriptResolution(for record: AgentChatSessionRecord) {
        let key: CodexTranscriptResolutionKey = (
            sessionID: record.sessionID,
            transcriptPath: record.transcriptPath
        )
        if let currentKey = codexTranscriptResolutionKeys[record.sessionID],
           currentKey.sessionID == key.sessionID,
           currentKey.transcriptPath == key.transcriptPath {
            return
        }

        clearCodexTranscriptResolution(sessionID: record.sessionID)
        codexTranscriptResolutionKeys[record.sessionID] = key
        let scanTask = detachedCodexTranscriptResolutionTask(for: record)
        codexTranscriptResolutionTasks[record.sessionID] = Task { @MainActor [
            weak self,
            scanTask,
            key
        ] in
            let resolved = await withTaskCancellationHandler {
                await scanTask.value
            } onCancel: {
                scanTask.cancel()
            }
            guard !Task.isCancelled else { return }
            self?.applyCodexTranscriptResolution(resolved, key: key)
        }
    }

    func clearCodexTranscriptResolution(sessionID: String) {
        codexTranscriptResolutionTasks[sessionID]?.cancel()
        codexTranscriptResolutionTasks[sessionID] = nil
        codexTranscriptResolutionKeys[sessionID] = nil
    }

    func codexTranscriptPathOffMain(for record: AgentChatSessionRecord) async -> String? {
        let scanTask = detachedCodexTranscriptResolutionTask(for: record)
        return await withTaskCancellationHandler {
            await scanTask.value
        } onCancel: {
            scanTask.cancel()
        }
    }

    func detachedCodexTranscriptResolutionTask(
        for record: AgentChatSessionRecord
    ) -> Task<String?, Never> {
        let resolver = self.resolver
        #if compiler(>=6.2)
        let resolveOperation: @concurrent @Sendable () async -> String? = { [resolver, record] in
            resolver.transcriptPath(for: record)
        }
        #else
        let resolveOperation: @Sendable () async -> String? = { [resolver, record] in
            resolver.transcriptPath(for: record)
        }
        #endif
        return Task.detached(priority: .utility, operation: resolveOperation)
    }

    func applyCodexTranscriptResolution(
        _ resolved: String?,
        key: CodexTranscriptResolutionKey
    ) {
        guard let currentKey = codexTranscriptResolutionKeys[key.sessionID],
              currentKey.sessionID == key.sessionID,
              currentKey.transcriptPath == key.transcriptPath else {
            return
        }
        codexTranscriptResolutionTasks[key.sessionID] = nil
        codexTranscriptResolutionKeys[key.sessionID] = nil
        applyDirectCodexTranscriptResolution(resolved, sessionID: key.sessionID)
    }

    func applyDirectCodexTranscriptResolution(_ resolved: String?, sessionID: String) {
        guard let record = registry.record(sessionID: sessionID),
              record.agentKind == .codex,
              record.state != .ended else {
            return
        }
        guard let resolved else {
            if resolver.recordedTranscriptPath(for: record) == nil {
                failedResolutions.insert(sessionID)
            } else {
                failedResolutions.remove(sessionID)
            }
            return
        }
        failedResolutions.remove(sessionID)
        if record.transcriptPath != resolved {
            registry.update(sessionID: sessionID) { $0.transcriptPath = resolved }
        }
    }
}
