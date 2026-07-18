import CmuxFoundation
import Darwin
import Foundation

/// Completes a hook-store session after cmux observes the root TUI return to its
/// shell prompt. Work runs on a utility-priority task and uses the same sidecar lock as
/// hook writers, so terminal UI delivery never waits on disk or JSON work.
struct AgentHookSessionStateWriter: Sendable {
    /// The hook stores are process-wide files, so app-originated mutations share
    /// one actor. Timestamp fences make each mutation safe even if independently
    /// created tasks reach this actor in a different order.
    private actor WriteCoordinator {
        func complete(
            using writer: AgentHookSessionStateWriter,
            provider: String,
            stateURL: URL,
            sessionId: String,
            expectedRecordUpdatedAt: TimeInterval?,
            now: TimeInterval
        ) {
            writer.complete(
                provider: provider,
                stateURL: stateURL,
                sessionId: sessionId,
                expectedRecordUpdatedAt: expectedRecordUpdatedAt,
                now: now
            )
        }

        func setLifecycle(
            _ lifecycle: AgentSessionLifecycleState,
            using writer: AgentHookSessionStateWriter,
            provider: String,
            stateURL: URL,
            sessionId: String,
            now: TimeInterval
        ) {
            writer.setLifecycle(
                lifecycle,
                provider: provider,
                stateURL: stateURL,
                sessionId: sessionId,
                now: now
            )
        }

        func projectRestoredHibernationsToLegacy(
            using writer: AgentHookSessionStateWriter,
            provider: String,
            stateURL: URL,
            requests: [RestoredHibernationAdoptionRequest],
            now: TimeInterval
        ) {
            writer.projectRestoredHibernationsToLegacy(
                provider: provider,
                stateURL: stateURL,
                requests: requests,
                now: now
            )
        }

    }

    private static let writeCoordinator = WriteCoordinator()
    struct RestoredHibernationAdoptionRequest: Sendable {
        var agent: SessionRestorableAgentSnapshot
        var previousWorkspaceId: UUID?
        var previousSurfaceId: UUID
        var workspaceId: UUID
        var surfaceId: UUID
        var rebindWorkspaceActiveSlot = false
    }
    private let homeDirectory: String
    private let environment: [String: String]

    init(
        homeDirectory: String = NSHomeDirectory(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.homeDirectory = homeDirectory
        self.environment = environment
    }

    static func rootExitCandidate(
        previousWasRunning: Bool,
        isPromptIdle: Bool,
        isHibernated: Bool,
        binding: SurfaceResumeBindingSnapshot?
    ) -> SurfaceResumeBindingSnapshot? {
        previousWasRunning && isPromptIdle && !isHibernated && binding?.isAgentHookBinding == true
            ? binding
            : nil
    }

    static func recordRootExitIfNeeded(
        binding: SurfaceResumeBindingSnapshot?
    ) {
        guard let kindValue = binding?.kind,
              let kind = RestorableAgentKind(rawValue: kindValue),
              let sessionId = binding?.checkpointId else { return }
        AgentHookSessionStateWriter().schedule(
            kind: kind,
            sessionId: sessionId,
            expectedRecordUpdatedAt: binding?.updatedAt
        )
    }

    static func recordLifecycle(
        agent: SessionRestorableAgentSnapshot?,
        state: AgentSessionLifecycleState
    ) {
        guard let agent else { return }
        AgentHookSessionStateWriter().scheduleLifecycle(
            kind: agent.kind,
            sessionId: agent.sessionId,
            state: state
        )
    }

    @discardableResult
    static func recordRestoredHibernation(
        agent: SessionRestorableAgentSnapshot,
        previousWorkspaceId: UUID?,
        previousSurfaceId: UUID,
        workspaceId: UUID,
        surfaceId: UUID
    ) -> Bool {
        recordRestoredHibernations([
            RestoredHibernationAdoptionRequest(
                agent: agent,
                previousWorkspaceId: previousWorkspaceId,
                previousSurfaceId: previousSurfaceId,
                workspaceId: workspaceId,
                surfaceId: surfaceId
            ),
        ]).contains(surfaceId)
    }

    static func recordRestoredHibernations(
        _ requests: [RestoredHibernationAdoptionRequest],
        now: TimeInterval = Date().timeIntervalSince1970
    ) -> Set<UUID> {
        AgentHookSessionStateWriter().recordRestoredHibernationsSynchronously(
            requests,
            now: now
        )
    }

    private func recordRestoredHibernationsSynchronously(
        _ requests: [RestoredHibernationAdoptionRequest],
        now: TimeInterval
    ) -> Set<UUID> {
        var adoptedSurfaceIds = Set<UUID>()
        for (provider, providerRequests) in Dictionary(grouping: requests, by: { $0.agent.kind.rawValue }) {
            guard let kind = providerRequests.first?.agent.kind else { continue }
            let stateURL = kind.hookStoreFileURL(
                homeDirectory: homeDirectory,
                environment: environment
            )
            let adopted = adoptRestoredHibernationsHoldingLegacyReadLock(
                provider: provider,
                stateURL: stateURL,
                requests: providerRequests,
                now: now,
                busyTimeoutMilliseconds: 25
            )
            guard !adopted.isEmpty else { continue }
            adoptedSurfaceIds.formUnion(adopted.map(\.surfaceId))
            Task(priority: .utility) {
                await Self.writeCoordinator.projectRestoredHibernationsToLegacy(
                    using: self,
                    provider: provider,
                    stateURL: stateURL,
                    requests: adopted,
                    now: now
                )
            }
        }
        return adoptedSurfaceIds
    }

    func schedule(
        kind: RestorableAgentKind,
        sessionId: String,
        expectedRecordUpdatedAt: TimeInterval? = nil,
        now: TimeInterval = Date().timeIntervalSince1970
    ) {
        let normalized = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        let stateURL = kind.hookStoreFileURL(
            homeDirectory: homeDirectory,
            environment: environment
        )
        Task(priority: .utility) {
            await Self.writeCoordinator.complete(
                using: self,
                provider: kind.rawValue,
                stateURL: stateURL,
                sessionId: normalized,
                expectedRecordUpdatedAt: expectedRecordUpdatedAt,
                now: now
            )
        }
    }

    func completeSynchronously(
        kind: RestorableAgentKind,
        sessionId: String,
        expectedRecordUpdatedAt: TimeInterval? = nil,
        now: TimeInterval
    ) {
        let normalized = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        complete(
            provider: kind.rawValue,
            stateURL: kind.hookStoreFileURL(
                homeDirectory: homeDirectory,
                environment: environment
            ),
            sessionId: normalized,
            expectedRecordUpdatedAt: expectedRecordUpdatedAt,
            now: now
        )
    }

    func scheduleLifecycle(
        kind: RestorableAgentKind,
        sessionId: String,
        state: AgentSessionLifecycleState,
        now: TimeInterval = Date().timeIntervalSince1970
    ) {
        let normalized = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        let stateURL = kind.hookStoreFileURL(
            homeDirectory: homeDirectory,
            environment: environment
        )
        Task(priority: .utility) {
            await Self.writeCoordinator.setLifecycle(
                state,
                using: self,
                provider: kind.rawValue,
                stateURL: stateURL,
                sessionId: normalized,
                now: now
            )
        }
    }

    func setLifecycleSynchronously(
        kind: RestorableAgentKind,
        sessionId: String,
        state: AgentSessionLifecycleState,
        now: TimeInterval
    ) {
        let normalized = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        setLifecycle(
            state,
            provider: kind.rawValue,
            stateURL: kind.hookStoreFileURL(
                homeDirectory: homeDirectory,
                environment: environment
            ),
            sessionId: normalized,
            now: now
        )
    }

    @discardableResult
    func recordRestoredHibernationSynchronously(
        kind: RestorableAgentKind,
        sessionId: String,
        previousWorkspaceId: String?,
        previousSurfaceId: String,
        workspaceId: String,
        surfaceId: String,
        now: TimeInterval = Date().timeIntervalSince1970
    ) -> Bool {
        guard let normalizedSessionId = normalized(sessionId),
              let normalizedPreviousSurfaceId = normalized(previousSurfaceId),
              let normalizedWorkspaceId = normalized(workspaceId),
              let normalizedSurfaceId = normalized(surfaceId),
              let previousSurfaceUUID = UUID(uuidString: normalizedPreviousSurfaceId),
              let workspaceUUID = UUID(uuidString: normalizedWorkspaceId),
              let surfaceUUID = UUID(uuidString: normalizedSurfaceId) else { return false }
        let previousWorkspaceUUID: UUID?
        if let previousWorkspaceId {
            guard let value = normalized(previousWorkspaceId),
                  let uuid = UUID(uuidString: value) else { return false }
            previousWorkspaceUUID = uuid
        } else {
            previousWorkspaceUUID = nil
        }
        let request = RestoredHibernationAdoptionRequest(
            agent: SessionRestorableAgentSnapshot(
                kind: kind,
                sessionId: normalizedSessionId,
                workingDirectory: nil,
                launchCommand: nil
            ),
            previousWorkspaceId: previousWorkspaceUUID,
            previousSurfaceId: previousSurfaceUUID,
            workspaceId: workspaceUUID,
            surfaceId: surfaceUUID
        )
        return recordRestoredHibernationsSynchronously([request], now: now).contains(surfaceUUID)
    }

    private func complete(
        provider: String,
        stateURL: URL,
        sessionId: String,
        expectedRecordUpdatedAt: TimeInterval?,
        now: TimeInterval
    ) {
        let registry = preparedRegistry(provider: provider, stateURL: stateURL)
        _ = try? registry.patchRecord(
            provider: provider,
            sessionID: sessionId,
            updatedAt: now,
            activeSlotRemoval: expectedRecordUpdatedAt.map {
                .updatedThrough($0)
            } ?? .all,
            shouldMutate: { record in
                guard let expectedRecordUpdatedAt else { return true }
                guard let actualUpdatedAt = record["updatedAt"] as? TimeInterval else { return false }
                return actualUpdatedAt <= expectedRecordUpdatedAt
            }
        ) { registryRecord in
            applyCompletion(to: &registryRecord, now: now)
        }

        let wroteLegacy = updateLegacyRecordNonblocking(stateURL: stateURL, sessionID: sessionId) { root, record in
            if let expectedRecordUpdatedAt {
                guard let actualUpdatedAt = record["updatedAt"] as? TimeInterval,
                      actualUpdatedAt <= expectedRecordUpdatedAt else { return false }
            }
            applyCompletion(to: &record, now: now)
            root["activeSessionsByWorkspace"] = removingSession(
                sessionId,
                from: root["activeSessionsByWorkspace"]
            )
            root["activeSessionsBySurface"] = removingSession(
                sessionId,
                from: root["activeSessionsBySurface"]
            )
            return true
        }
        if wroteLegacy { markLegacySource(provider: provider, stateURL: stateURL) }
    }

    private func setLifecycle(
        _ lifecycle: AgentSessionLifecycleState,
        provider: String,
        stateURL: URL,
        sessionId: String,
        now: TimeInterval
    ) {
        let registry = preparedRegistry(provider: provider, stateURL: stateURL)
        _ = try? registry.patchRecord(
            provider: provider,
            sessionID: sessionId,
            updatedAt: now,
            shouldMutate: { record in
                guard let actualUpdatedAt = record["updatedAt"] as? TimeInterval else { return false }
                return actualUpdatedAt <= now
            }
        ) { registryRecord in
            applyLifecycle(lifecycle, to: &registryRecord, now: now)
        }
        let wroteLegacy = updateLegacyRecordNonblocking(stateURL: stateURL, sessionID: sessionId) { _, record in
            guard let actualUpdatedAt = record["updatedAt"] as? TimeInterval,
                  actualUpdatedAt <= now else { return false }
            applyLifecycle(lifecycle, to: &record, now: now)
            return true
        }
        if wroteLegacy { markLegacySource(provider: provider, stateURL: stateURL) }
    }

    private func adoptRestoredHibernationsHoldingLegacyReadLock(
        provider: String,
        stateURL: URL,
        requests: [RestoredHibernationAdoptionRequest],
        now: TimeInterval,
        busyTimeoutMilliseconds: Int32
    ) -> [RestoredHibernationAdoptionRequest] {
        let normalizedRequests = requests.compactMap { request -> (RestoredHibernationAdoptionRequest, String)? in
            guard let sessionId = normalized(request.agent.sessionId) else { return nil }
            return (request, sessionId)
        }
        guard !normalizedRequests.isEmpty else { return [] }
        let descriptor = open(
            stateURL.path + ".lock",
            O_CREAT | O_RDWR,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard descriptor >= 0 else { return [] }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_SH | LOCK_NB) == 0 else { return [] }
        defer { _ = flock(descriptor, LOCK_UN) }

        let registry = registry(
            provider: provider,
            stateURL: stateURL,
            busyTimeoutMilliseconds: busyTimeoutMilliseconds
        )
        do {
            return try registry.withLegacySourceRebindBatch(
                provider: provider,
                legacyURL: stateURL
            ) { batch in
                var adopted: [RestoredHibernationAdoptionRequest] = []
                adopted.reserveCapacity(normalizedRequests.count)
                for (request, sessionId) in normalizedRequests {
                    let previousSurfaceSlot = CmuxAgentSessionRegistry.ActiveSlotKey(
                        scope: .surface,
                        scopeID: request.previousSurfaceId.uuidString
                    )
                    let activeSurfaceSlot = CmuxAgentSessionRegistry.ActiveSlotKey(
                        scope: .surface,
                        scopeID: request.surfaceId.uuidString
                    )
                    let previousSurfaceOwner = try batch.activeSlotSessionID(
                        provider: provider,
                        key: previousSurfaceSlot
                    )
                    let activeSurfaceOwner = try batch.activeSlotSessionID(
                        provider: provider,
                        key: activeSurfaceSlot
                    )
                    let previousWorkspaceSlot = request.previousWorkspaceId.map {
                        CmuxAgentSessionRegistry.ActiveSlotKey(
                            scope: .workspace,
                            scopeID: $0.uuidString
                        )
                    }
                    let rebindWorkspaceActiveSlot = try previousWorkspaceSlot.map {
                        try batch.activeSlotSessionID(provider: provider, key: $0) == sessionId
                    } ?? false
                    var previousSlots = [previousSurfaceSlot]
                    var activeSlots = [activeSurfaceSlot]
                    if let previousWorkspaceSlot, rebindWorkspaceActiveSlot {
                        previousSlots.append(previousWorkspaceSlot)
                        activeSlots.append(
                            CmuxAgentSessionRegistry.ActiveSlotKey(
                                scope: .workspace,
                                scopeID: request.workspaceId.uuidString
                            )
                        )
                    }
                    let result = try batch.patchRecordRebindingActiveSlots(
                        provider: provider,
                        sessionID: sessionId,
                        updatedAt: now,
                        previousSlots: previousSlots,
                        activeSlots: activeSlots,
                        shouldMutate: { record in
                            guard restoredRecordCanBeAdopted(
                                record,
                                previousWorkspaceId: request.previousWorkspaceId?.uuidString,
                                previousSurfaceId: request.previousSurfaceId.uuidString,
                                workspaceId: request.workspaceId.uuidString,
                                surfaceId: request.surfaceId.uuidString,
                                now: now
                            ),
                            let recordWorkspaceId = normalized(record["workspaceId"] as? String),
                            let recordSurfaceId = normalized(record["surfaceId"] as? String) else {
                                return false
                            }
                            // A record still on its persisted binding needs the
                            // old singular surface slot. An idempotent repeat
                            // after a successful transfer instead needs the new
                            // slot. Workspace slots differ: sibling panels can
                            // share one workspace, so only its actual owner
                            // transfers that optional slot above.
                            let alreadyAdopted = identifiersEqual(
                                recordWorkspaceId,
                                request.workspaceId.uuidString
                            ) && identifiersEqual(
                                recordSurfaceId,
                                request.surfaceId.uuidString
                            )
                            return alreadyAdopted
                                ? activeSurfaceOwner == sessionId
                                : previousSurfaceOwner == sessionId
                        }
                    ) { record in
                        applyRestoredHibernation(
                            to: &record,
                            workspaceId: request.workspaceId.uuidString,
                            surfaceId: request.surfaceId.uuidString,
                            now: now
                        )
                    }
                    if result == .patched {
                        var adoptedRequest = request
                        adoptedRequest.rebindWorkspaceActiveSlot = rebindWorkspaceActiveSlot
                        adopted.append(adoptedRequest)
                    }
                }
                return adopted
            }
        } catch {
            return []
        }
    }

    func projectRestoredHibernationsToLegacy(
        provider: String,
        stateURL: URL,
        requests: [RestoredHibernationAdoptionRequest],
        now: TimeInterval
    ) {
        let descriptor = open(
            stateURL.path + ".lock",
            O_CREAT | O_RDWR,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard descriptor >= 0 else { return }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { return }
        defer { _ = flock(descriptor, LOCK_UN) }
        guard let data = try? Data(contentsOf: stateURL),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var sessions = root["sessions"] as? [String: Any] else { return }
        let rawWorkspaceSlots = root["activeSessionsByWorkspace"]
        let rawSurfaceSlots = root["activeSessionsBySurface"]
        guard rawWorkspaceSlots == nil || rawWorkspaceSlots is [String: Any],
              rawSurfaceSlots == nil || rawSurfaceSlots is [String: Any] else { return }
        let currentWorkspaceSlots = rawWorkspaceSlots as? [String: Any] ?? [:]
        let currentSurfaceSlots = rawSurfaceSlots as? [String: Any] ?? [:]

        func targetSlotIsAvailable(
            _ slots: [String: Any],
            scopeId: String,
            sessionId: String
        ) -> Bool {
            guard let value = slots[scopeId] else { return true }
            guard let slot = value as? [String: Any],
                  let owner = normalized(slot["sessionId"] as? String),
                  let updatedAt = slot["updatedAt"] as? TimeInterval else { return false }
            return owner == sessionId && updatedAt <= now
        }

        var accepted: [(request: RestoredHibernationAdoptionRequest, sessionId: String)] = []
        accepted.reserveCapacity(requests.count)
        for request in requests {
            guard let sessionId = normalized(request.agent.sessionId),
                  (!request.rebindWorkspaceActiveSlot || targetSlotIsAvailable(
                    currentWorkspaceSlots,
                    scopeId: request.workspaceId.uuidString,
                    sessionId: sessionId
                  )),
                  targetSlotIsAvailable(
                    currentSurfaceSlots,
                    scopeId: request.surfaceId.uuidString,
                    sessionId: sessionId
                  ),
                  var record = sessions[sessionId] as? [String: Any],
                  restoredRecordCanBeAdopted(
                    record,
                    previousWorkspaceId: request.previousWorkspaceId?.uuidString,
                    previousSurfaceId: request.previousSurfaceId.uuidString,
                    workspaceId: request.workspaceId.uuidString,
                    surfaceId: request.surfaceId.uuidString,
                    now: now
                  ) else { continue }
            applyRestoredHibernation(
                to: &record,
                workspaceId: request.workspaceId.uuidString,
                surfaceId: request.surfaceId.uuidString,
                now: now
            )
            sessions[sessionId] = record
            accepted.append((request, sessionId))
        }
        guard !accepted.isEmpty else { return }

        let acceptedSessionIds = Set(accepted.map { $0.sessionId })
        let workspaceAcceptedSessionIds = Set(accepted.compactMap {
            $0.request.rebindWorkspaceActiveSlot ? $0.sessionId : nil
        })
        func removeAcceptedSessions(
            from value: Any?,
            acceptedSessionIds: Set<String>
        ) -> (remaining: [String: Any], templates: [String: [String: Any]]) {
            var remaining = value as? [String: Any] ?? [:]
            var templates: [String: [String: Any]] = [:]
            for (scopeId, value) in remaining {
                guard let slot = value as? [String: Any],
                      let sessionId = normalized(slot["sessionId"] as? String),
                      acceptedSessionIds.contains(sessionId) else { continue }
                let candidateUpdatedAt = slot["updatedAt"] as? TimeInterval ?? -.infinity
                let storedUpdatedAt = templates[sessionId]?["updatedAt"] as? TimeInterval ?? -.infinity
                if candidateUpdatedAt >= storedUpdatedAt {
                    templates[sessionId] = slot
                }
                remaining.removeValue(forKey: scopeId)
            }
            return (remaining, templates)
        }

        var workspaceSlots = removeAcceptedSessions(
            from: currentWorkspaceSlots,
            acceptedSessionIds: workspaceAcceptedSessionIds
        )
        var surfaceSlots = removeAcceptedSessions(
            from: currentSurfaceSlots,
            acceptedSessionIds: acceptedSessionIds
        )
        for item in accepted {
            if item.request.rebindWorkspaceActiveSlot {
                var workspaceSlot = workspaceSlots.templates[item.sessionId] ?? [:]
                workspaceSlot["sessionId"] = item.sessionId
                workspaceSlot["updatedAt"] = now
                workspaceSlots.remaining[item.request.workspaceId.uuidString] = workspaceSlot
            }

            var surfaceSlot = surfaceSlots.templates[item.sessionId] ?? [:]
            surfaceSlot["sessionId"] = item.sessionId
            surfaceSlot["updatedAt"] = now
            surfaceSlots.remaining[item.request.surfaceId.uuidString] = surfaceSlot
        }
        root["sessions"] = sessions
        root["activeSessionsByWorkspace"] = workspaceSlots.remaining
        root["activeSessionsBySurface"] = surfaceSlots.remaining
        guard JSONSerialization.isValidJSONObject(root),
              let encoded = try? JSONSerialization.data(
                withJSONObject: root,
                options: [.prettyPrinted, .sortedKeys]
              ),
              replacePrivateStateFile(with: encoded, at: stateURL) else { return }
        markLegacySource(provider: provider, stateURL: stateURL)
    }

    private func applyCompletion(to record: inout [String: Any], now: TimeInterval) {
        record["completedAt"] = now
        record["updatedAt"] = now
        record["runtimeStatus"] = "idle"
        record["agentLifecycle"] = "idle"
        if record["foregroundState"] as? String != "interrupted" {
            record["foregroundState"] = "completed"
        }
        record["attentionState"] = "none"
        record["sessionState"] = "ended"
        record["restoreAuthority"] = false
        record.removeValue(forKey: "activeRunId")
        record["runs"] = completeRuns(record["runs"], now: now)
        record["workloads"] = cancelWorkloads(record["workloads"], now: now)
    }

    private func applyLifecycle(
        _ lifecycle: AgentSessionLifecycleState,
        to record: inout [String: Any],
        now: TimeInterval
    ) {
        record["sessionState"] = lifecycle.rawValue
        record["updatedAt"] = now
        if let runtime = runtimePayload() {
            record["cmuxRuntime"] = runtime
            record["runs"] = assigningRuntime(
                runtime,
                to: record["runs"],
                activeRunId: record["activeRunId"] as? String
            )
        }
    }

    private func applyRestoredHibernation(
        to record: inout [String: Any],
        workspaceId: String,
        surfaceId: String,
        now: TimeInterval
    ) {
        applyLifecycle(.hibernated, to: &record, now: now)
        record["workspaceId"] = workspaceId
        record["surfaceId"] = surfaceId
    }

    private func restoredRecordCanBeAdopted(
        _ record: [String: Any],
        previousWorkspaceId: String?,
        previousSurfaceId: String,
        workspaceId: String,
        surfaceId: String,
        now: TimeInterval
    ) -> Bool {
        guard record["sessionState"] as? String == AgentSessionLifecycleState.hibernated.rawValue,
              let actualUpdatedAt = record["updatedAt"] as? TimeInterval,
              actualUpdatedAt <= now,
              let recordWorkspaceId = normalized(record["workspaceId"] as? String),
              let recordSurfaceId = normalized(record["surfaceId"] as? String) else {
            return false
        }
        let alreadyAdopted = identifiersEqual(recordWorkspaceId, workspaceId)
            && identifiersEqual(recordSurfaceId, surfaceId)
        let matchesPreviousWorkspace = previousWorkspaceId.map {
            identifiersEqual(recordWorkspaceId, $0)
        } ?? true
        let matchesPreviousBinding = matchesPreviousWorkspace
            && identifiersEqual(recordSurfaceId, previousSurfaceId)
        return alreadyAdopted || matchesPreviousBinding
    }

    private func updateLegacyRecordNonblocking(
        stateURL: URL,
        sessionID: String,
        mutate: (inout [String: Any], inout [String: Any]) -> Bool
    ) -> Bool {
        let lockPath = stateURL.path + ".lock"
        let descriptor = open(lockPath, O_CREAT | O_RDWR, mode_t(S_IRUSR | S_IWUSR))
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { return false }
        defer { _ = flock(descriptor, LOCK_UN) }
        guard let data = try? Data(contentsOf: stateURL),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var sessions = root["sessions"] as? [String: Any],
              var record = sessions[sessionID] as? [String: Any],
              mutate(&root, &record) else { return false }
        sessions[sessionID] = record
        root["sessions"] = sessions
        guard JSONSerialization.isValidJSONObject(root),
              let encoded = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) else {
            return false
        }
        return replacePrivateStateFile(with: encoded, at: stateURL)
    }

    private func preparedRegistry(
        provider: String,
        stateURL: URL
    ) -> CmuxAgentSessionRegistry {
        let registry = registry(provider: provider, stateURL: stateURL)
        _ = try? registry.snapshotImportingLegacy(
            provider: provider,
            legacyURL: stateURL
        )
        return registry
    }

    private func registry(
        provider: String,
        stateURL: URL,
        busyTimeoutMilliseconds: Int32 = 100
    ) -> CmuxAgentSessionRegistry {
        let registryURL: URL
        if let explicit = environment["CMUX_AGENT_SESSION_REGISTRY_PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !explicit.isEmpty {
            registryURL = URL(fileURLWithPath: NSString(string: explicit).expandingTildeInPath)
        } else {
            registryURL = stateURL.deletingLastPathComponent()
                .appendingPathComponent(CmuxAgentSessionRegistry.filename, isDirectory: false)
        }
        return CmuxAgentSessionRegistry(
            url: registryURL,
            busyTimeoutMilliseconds: busyTimeoutMilliseconds
        )
    }

    private func markLegacySource(provider: String, stateURL: URL) {
        guard let stamp = CmuxAgentSessionRegistry.LegacyStamp.read(path: stateURL.path) else { return }
        try? registry(provider: provider, stateURL: stateURL).markLegacySource(
            provider: provider,
            stamp: stamp
        )
    }

    private func replacePrivateStateFile(with data: Data, at stateURL: URL) -> Bool {
        let fileManager = FileManager.default
        let temporaryURL = stateURL.deletingLastPathComponent()
            .appendingPathComponent(".\(stateURL.lastPathComponent).\(UUID().uuidString).tmp")
        defer { try? fileManager.removeItem(at: temporaryURL) }
        guard fileManager.createFile(
            atPath: temporaryURL.path,
            contents: data,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o600))]
        ) else { return false }
        let renameResult = temporaryURL.path.withCString { source in
            stateURL.path.withCString { destination in
                Darwin.rename(source, destination)
            }
        }
        guard renameResult == 0 else { return false }
        // Keep the invariant even on filesystems that do not preserve the
        // temporary file's mode across replacement.
        _ = chmod(stateURL.path, S_IRUSR | S_IWUSR)
        return true
    }

    private func completeRuns(_ value: Any?, now: TimeInterval) -> [[String: Any]] {
        guard let runs = value as? [[String: Any]] else { return [] }
        return runs.map { run in
            var run = run
            if run["endedAt"] == nil {
                run["endedAt"] = now
                run["updatedAt"] = now
                run["restoreAuthority"] = false
            }
            return run
        }
    }

    private func runtimePayload() -> [String: Any]? {
        guard let id = environment["CMUX_RUNTIME_ID"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !id.isEmpty else { return nil }
        var payload: [String: Any] = ["id": id]
        if let socketPath = environment["CMUX_SOCKET_PATH"], !socketPath.isEmpty {
            payload["socketPath"] = socketPath
        }
        if let bundleIdentifier = environment["CMUX_BUNDLE_ID"], !bundleIdentifier.isEmpty {
            payload["bundleIdentifier"] = bundleIdentifier
        }
        return payload
    }

    private func assigningRuntime(
        _ runtime: [String: Any],
        to value: Any?,
        activeRunId: String?
    ) -> [[String: Any]] {
        guard let runs = value as? [[String: Any]], let activeRunId else { return value as? [[String: Any]] ?? [] }
        return runs.map { run in
            guard run["runId"] as? String == activeRunId else { return run }
            var updated = run
            updated["cmuxRuntime"] = runtime
            return updated
        }
    }

    private func cancelWorkloads(_ value: Any?, now: TimeInterval) -> [[String: Any]] {
        guard let workloads = value as? [[String: Any]] else { return [] }
        let activePhases: Set<String> = ["queued", "running", "watching", "waiting"]
        return workloads.map { workload in
            var workload = workload
            if let phase = workload["phase"] as? String, activePhases.contains(phase) {
                workload["phase"] = "cancelled"
                workload["updatedAt"] = now
                workload["endedAt"] = now
                workload["endReason"] = "root_exited"
            }
            return workload
        }
    }

    private func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    private func identifiersEqual(_ lhs: String, _ rhs: String) -> Bool {
        lhs.caseInsensitiveCompare(rhs) == .orderedSame
    }

    private func removingSession(_ sessionId: String, from value: Any?) -> [String: Any] {
        guard var records = value as? [String: Any] else { return [:] }
        for (key, value) in records {
            guard let record = value as? [String: Any],
                  record["sessionId"] as? String == sessionId else { continue }
            records.removeValue(forKey: key)
        }
        return records
    }
}
