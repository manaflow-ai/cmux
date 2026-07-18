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

        func projectHibernatedResumesToLegacy(
            using writer: AgentHookSessionStateWriter,
            provider: String,
            stateURL: URL,
            claims: [HibernatedResumeAuthorityClaim],
            now: TimeInterval
        ) {
            writer.projectHibernatedResumesToLegacy(
                provider: provider,
                stateURL: stateURL,
                claims: claims,
                now: now
            )
        }

        func projectEstablishedHibernationToLegacy(
            using writer: AgentHookSessionStateWriter,
            provider: String,
            stateURL: URL,
            request: HibernatedResumeAuthorityRequest,
            legacyStampAtClaim: CmuxAgentSessionRegistry.LegacyStamp?,
            now: TimeInterval
        ) {
            writer.projectEstablishedHibernationToLegacy(
                provider: provider,
                stateURL: stateURL,
                request: request,
                legacyStampAtClaim: legacyStampAtClaim,
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
    enum RestoredHibernationAdoptionOutcome: Equatable, Sendable {
        case adopted
        case rejected
        case unavailable
    }
    struct HibernatedResumeAuthorityRequest: Sendable {
        var agent: SessionRestorableAgentSnapshot
        var workspaceId: UUID
        var surfaceId: UUID
    }
    enum HibernatedResumeAuthorityOutcome: Equatable, Sendable {
        case acquired
        case rejected
        case unavailable
    }
    struct HibernatedResumeAuthorityClaim: Sendable {
        var request: HibernatedResumeAuthorityRequest
        var legacyStampAtClaim: CmuxAgentSessionRegistry.LegacyStamp?
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
        Set(recordRestoredHibernationOutcomes(requests, now: now).compactMap {
            $0.value == .adopted ? $0.key : nil
        })
    }

    static func recordRestoredHibernationOutcomes(
        _ requests: [RestoredHibernationAdoptionRequest],
        now: TimeInterval = Date().timeIntervalSince1970
    ) -> [UUID: RestoredHibernationAdoptionOutcome] {
        AgentHookSessionStateWriter().recordRestoredHibernationOutcomesSynchronously(
            requests,
            now: now
        )
    }

    /// Atomically claims the durable surface owner immediately before cmux
    /// queues a hibernated agent's resume input. A missing or changed slot is a
    /// lost authority lease, even when the record still carries the old binding.
    @discardableResult
    static func acquireHibernatedResumeAuthority(
        agent: SessionRestorableAgentSnapshot,
        workspaceId: UUID,
        surfaceId: UUID,
        now: TimeInterval = Date().timeIntervalSince1970
    ) -> HibernatedResumeAuthorityOutcome {
        acquireHibernatedResumeAuthorities([
            HibernatedResumeAuthorityRequest(
                agent: agent,
                workspaceId: workspaceId,
                surfaceId: surfaceId
            ),
        ], now: now)[surfaceId] ?? .unavailable
    }

    /// Claims many hibernated records with one bounded SQLite transaction per
    /// provider. Rejected siblings do not prevent independent claims from
    /// succeeding in the same transaction.
    static func acquireHibernatedResumeAuthorities(
        _ requests: [HibernatedResumeAuthorityRequest],
        now: TimeInterval = Date().timeIntervalSince1970
    ) -> [UUID: HibernatedResumeAuthorityOutcome] {
        AgentHookSessionStateWriter().acquireHibernatedResumeAuthoritiesSynchronously(
            requests,
            now: now
        )
    }

    /// Establishes the durable hibernated lease at the native teardown commit
    /// point. Failure leaves the live runtime intact and retryable.
    static func establishHibernatedAuthority(
        agent: SessionRestorableAgentSnapshot,
        workspaceId: UUID,
        surfaceId: UUID,
        now: TimeInterval = Date().timeIntervalSince1970
    ) -> HibernatedResumeAuthorityOutcome {
        AgentHookSessionStateWriter().establishHibernatedAuthoritySynchronously(
            request: HibernatedResumeAuthorityRequest(
                agent: agent,
                workspaceId: workspaceId,
                surfaceId: surfaceId
            ),
            now: now
        )
    }

    private func recordRestoredHibernationOutcomesSynchronously(
        _ requests: [RestoredHibernationAdoptionRequest],
        now: TimeInterval
    ) -> [UUID: RestoredHibernationAdoptionOutcome] {
        var outcomes: [UUID: RestoredHibernationAdoptionOutcome] = [:]
        for (provider, providerRequests) in Dictionary(grouping: requests, by: { $0.agent.kind.rawValue }) {
            guard let kind = providerRequests.first?.agent.kind else { continue }
            let stateURL = kind.hookStoreFileURL(
                homeDirectory: homeDirectory,
                environment: environment
            )
            let providerResult = adoptRestoredHibernationsHoldingLegacyReadLock(
                provider: provider,
                stateURL: stateURL,
                requests: providerRequests,
                now: now,
                busyTimeoutMilliseconds: 25
            )
            outcomes.merge(providerResult.outcomes) { _, new in new }
            let adopted = providerResult.adopted
            guard !adopted.isEmpty else { continue }
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
        return outcomes
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
        return recordRestoredHibernationOutcomesSynchronously(
            [request],
            now: now
        )[surfaceUUID] == .adopted
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

    private func establishHibernatedAuthoritySynchronously(
        request: HibernatedResumeAuthorityRequest,
        now: TimeInterval
    ) -> HibernatedResumeAuthorityOutcome {
        guard let sessionId = normalized(request.agent.sessionId) else { return .rejected }
        let provider = request.agent.kind.rawValue
        let stateURL = request.agent.kind.hookStoreFileURL(
            homeDirectory: homeDirectory,
            environment: environment
        )
        let legacyStampAtClaim = CmuxAgentSessionRegistry.LegacyStamp.read(path: stateURL.path)
        let result: CmuxAgentSessionRegistry.RecordRebindResult
        do {
            result = try registry(
                provider: provider,
                stateURL: stateURL,
                busyTimeoutMilliseconds: 25
            ).patchRecordRebindingActiveSlots(
                provider: provider,
                sessionID: sessionId,
                updatedAt: now,
                previousSlots: [],
                activeSlots: [.init(scope: .surface, scopeID: request.surfaceId.uuidString)],
                requireExistingActiveSlots: true,
                monotonicUpdatedAt: true,
                shouldMutate: { record in
                    let allowedStates: Set<String> = [
                        AgentSessionLifecycleState.active.rawValue,
                        AgentSessionLifecycleState.restoring.rawValue,
                        AgentSessionLifecycleState.hibernated.rawValue,
                    ]
                    guard let state = record["sessionState"] as? String,
                          allowedStates.contains(state),
                          record["restoreAuthority"] as? Bool != false,
                          !hasCompletion(record),
                          record["updatedAt"] is TimeInterval,
                          recordBelongsToCurrentRuntime(record),
                          let recordWorkspaceId = normalized(record["workspaceId"] as? String),
                          let recordSurfaceId = normalized(record["surfaceId"] as? String) else {
                        return false
                    }
                    return identifiersEqual(recordWorkspaceId, request.workspaceId.uuidString)
                        && identifiersEqual(recordSurfaceId, request.surfaceId.uuidString)
                }
            ) { record in
                let effectiveNow = max(now, record["updatedAt"] as? TimeInterval ?? now)
                applyLifecycle(.hibernated, to: &record, now: effectiveNow)
            }
        } catch {
            return .unavailable
        }
        guard result == .patched else { return .rejected }
        Task(priority: .utility) {
            await Self.writeCoordinator.projectEstablishedHibernationToLegacy(
                using: self,
                provider: provider,
                stateURL: stateURL,
                request: request,
                legacyStampAtClaim: legacyStampAtClaim,
                now: now
            )
        }
        return .acquired
    }

    private func acquireHibernatedResumeAuthoritiesSynchronously(
        _ requests: [HibernatedResumeAuthorityRequest],
        now: TimeInterval
    ) -> [UUID: HibernatedResumeAuthorityOutcome] {
        var outcomes: [UUID: HibernatedResumeAuthorityOutcome] = [:]
        for (provider, providerRequests) in Dictionary(
            grouping: requests,
            by: { $0.agent.kind.rawValue }
        ) {
            guard let kind = providerRequests.first?.agent.kind else { continue }
            let stateURL = kind.hookStoreFileURL(
                homeDirectory: homeDirectory,
                environment: environment
            )
            let normalizedRequests = providerRequests.compactMap {
                request -> (request: HibernatedResumeAuthorityRequest, sessionId: String)? in
                guard let sessionId = normalized(request.agent.sessionId) else {
                    outcomes[request.surfaceId] = .rejected
                    return nil
                }
                return (request, sessionId)
            }
            guard !normalizedRequests.isEmpty else { continue }
            let legacyStampAtClaim = CmuxAgentSessionRegistry.LegacyStamp.read(
                path: stateURL.path
            )
            let providerClaims: [HibernatedResumeAuthorityClaim]
            let providerOutcomes: [UUID: HibernatedResumeAuthorityOutcome]
            do {
                let result = try registry(
                    provider: provider,
                    stateURL: stateURL,
                    busyTimeoutMilliseconds: 25
                ).withRecordRebindBatch { batch in
                    var accepted: [HibernatedResumeAuthorityClaim] = []
                    var transactionOutcomes: [UUID: HibernatedResumeAuthorityOutcome] = [:]
                    accepted.reserveCapacity(normalizedRequests.count)
                    for (request, sessionId) in normalizedRequests {
                        let activeSurfaceSlot = CmuxAgentSessionRegistry.ActiveSlotKey(
                            scope: .surface,
                            scopeID: request.surfaceId.uuidString
                        )
                        let result = try batch.patchRecordRebindingActiveSlots(
                            provider: provider,
                            sessionID: sessionId,
                            updatedAt: now,
                            previousSlots: [],
                            activeSlots: [activeSurfaceSlot],
                            requireExistingActiveSlots: true,
                            monotonicUpdatedAt: true,
                            shouldMutate: { record in
                                guard record["sessionState"] as? String
                                        == AgentSessionLifecycleState.hibernated.rawValue,
                                      record["restoreAuthority"] as? Bool != false,
                                      !hasCompletion(record),
                                      record["updatedAt"] is TimeInterval,
                                      recordBelongsToCurrentRuntime(record),
                                      let recordWorkspaceId = normalized(record["workspaceId"] as? String),
                                      let recordSurfaceId = normalized(record["surfaceId"] as? String) else {
                                    return false
                                }
                                return identifiersEqual(
                                    recordWorkspaceId,
                                    request.workspaceId.uuidString
                                ) && identifiersEqual(
                                    recordSurfaceId,
                                    request.surfaceId.uuidString
                                )
                            }
                        ) { record in
                            let effectiveNow = max(
                                now,
                                record["updatedAt"] as? TimeInterval ?? now
                            )
                            applyLifecycle(.restoring, to: &record, now: effectiveNow)
                        }
                        if result == .patched {
                            transactionOutcomes[request.surfaceId] = .acquired
                            accepted.append(HibernatedResumeAuthorityClaim(
                                request: request,
                                legacyStampAtClaim: legacyStampAtClaim
                            ))
                        } else {
                            transactionOutcomes[request.surfaceId] = .rejected
                        }
                    }
                    return (accepted, transactionOutcomes)
                }
                providerClaims = result.0
                providerOutcomes = result.1
            } catch {
                for request in providerRequests {
                    outcomes[request.surfaceId] = .unavailable
                }
                continue
            }
            outcomes.merge(providerOutcomes) { _, new in new }
            guard !providerClaims.isEmpty else { continue }
            Task(priority: .utility) {
                await Self.writeCoordinator.projectHibernatedResumesToLegacy(
                    using: self,
                    provider: provider,
                    stateURL: stateURL,
                    claims: providerClaims,
                    now: now
                )
            }
        }
        return outcomes
    }

    private func adoptRestoredHibernationsHoldingLegacyReadLock(
        provider: String,
        stateURL: URL,
        requests: [RestoredHibernationAdoptionRequest],
        now: TimeInterval,
        busyTimeoutMilliseconds: Int32
    ) -> (
        adopted: [RestoredHibernationAdoptionRequest],
        outcomes: [UUID: RestoredHibernationAdoptionOutcome]
    ) {
        var initialOutcomes: [UUID: RestoredHibernationAdoptionOutcome] = [:]
        let normalizedRequests = requests.compactMap { request -> (RestoredHibernationAdoptionRequest, String)? in
            guard let sessionId = normalized(request.agent.sessionId) else {
                initialOutcomes[request.surfaceId] = .rejected
                return nil
            }
            return (request, sessionId)
        }
        guard !normalizedRequests.isEmpty else { return ([], initialOutcomes) }
        func unavailableResult() -> (
            adopted: [RestoredHibernationAdoptionRequest],
            outcomes: [UUID: RestoredHibernationAdoptionOutcome]
        ) {
            var outcomes = initialOutcomes
            for (request, _) in normalizedRequests {
                outcomes[request.surfaceId] = .unavailable
            }
            return ([], outcomes)
        }
        let descriptor = open(
            stateURL.path + ".lock",
            O_CREAT | O_RDWR,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard descriptor >= 0 else { return unavailableResult() }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_SH | LOCK_NB) == 0 else { return unavailableResult() }
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
                var outcomes = initialOutcomes
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
                        monotonicUpdatedAt: true,
                        shouldMutate: { record in
                            guard restoredRecordCanBeAdopted(
                                record,
                                previousWorkspaceId: request.previousWorkspaceId?.uuidString,
                                previousSurfaceId: request.previousSurfaceId.uuidString,
                                workspaceId: request.workspaceId.uuidString,
                                surfaceId: request.surfaceId.uuidString
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
                        let effectiveNow = max(now, record["updatedAt"] as? TimeInterval ?? now)
                        applyRestoredHibernation(
                            to: &record,
                            workspaceId: request.workspaceId.uuidString,
                            surfaceId: request.surfaceId.uuidString,
                            now: effectiveNow
                        )
                    }
                    if result == .patched {
                        var adoptedRequest = request
                        adoptedRequest.rebindWorkspaceActiveSlot = rebindWorkspaceActiveSlot
                        adopted.append(adoptedRequest)
                        outcomes[request.surfaceId] = .adopted
                    } else {
                        outcomes[request.surfaceId] = .rejected
                    }
                }
                return (adopted, outcomes)
            }
        } catch {
            return unavailableResult()
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
                  slot["updatedAt"] is TimeInterval else { return false }
            return owner == sessionId
        }

        var accepted: [(
            request: RestoredHibernationAdoptionRequest,
            sessionId: String,
            updatedAt: TimeInterval
        )] = []
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
                    surfaceId: request.surfaceId.uuidString
                  ),
                  let effectiveNow = monotonicTimestamp(
                    requested: now,
                    record: record,
                    slotCollections: [currentWorkspaceSlots, currentSurfaceSlots],
                    sessionId: sessionId
                  ) else { continue }
            applyRestoredHibernation(
                to: &record,
                workspaceId: request.workspaceId.uuidString,
                surfaceId: request.surfaceId.uuidString,
                now: effectiveNow
            )
            sessions[sessionId] = record
            accepted.append((request, sessionId, effectiveNow))
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
                workspaceSlot["updatedAt"] = item.updatedAt
                workspaceSlots.remaining[item.request.workspaceId.uuidString] = workspaceSlot
            }

            var surfaceSlot = surfaceSlots.templates[item.sessionId] ?? [:]
            surfaceSlot["sessionId"] = item.sessionId
            surfaceSlot["updatedAt"] = item.updatedAt
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

    private func projectHibernatedResumesToLegacy(
        provider: String,
        stateURL: URL,
        claims: [HibernatedResumeAuthorityClaim],
        now: TimeInterval
    ) {
        let sessionIds = Set(claims.compactMap { normalized($0.request.agent.sessionId) })
        guard let canonicalRecords = try? registry(
            provider: provider,
            stateURL: stateURL
        ).records(provider: provider, sessionIDs: sessionIds) else { return }
        let canonicalBySessionId = Dictionary(
            canonicalRecords.map { ($0.sessionID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
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
        var workspaceSlots = rawWorkspaceSlots as? [String: Any] ?? [:]
        var surfaceSlots = rawSurfaceSlots as? [String: Any] ?? [:]
        let currentLegacyStamp = CmuxAgentSessionRegistry.LegacyStamp.read(path: stateURL.path)
        var didMutate = false

        for claim in claims {
            let request = claim.request
            guard let sessionId = normalized(request.agent.sessionId),
                  let canonical = canonicalBySessionId[sessionId],
                  let canonicalRecord = try? JSONSerialization.jsonObject(
                    with: canonical.json
                  ) as? [String: Any],
                  lifecycleProjectionStillOwned(
                    canonicalRecord,
                    state: .restoring,
                    workspaceId: request.workspaceId,
                    surfaceId: request.surfaceId
                  ),
                  var record = sessions[sessionId] as? [String: Any] else { continue }
            let legacySourceIsUnchanged = claim.legacyStampAtClaim == currentLegacyStamp
            guard legacySourceIsUnchanged || recordBelongsToCurrentRuntime(record) else {
                continue
            }
            guard record["sessionState"] as? String == AgentSessionLifecycleState.hibernated.rawValue,
                  record["restoreAuthority"] as? Bool != false,
                  !hasCompletion(record),
                  targetSlotIsAvailable(
                    surfaceSlots,
                    scopeId: request.surfaceId.uuidString,
                    sessionId: sessionId
                  ),
                  let effectiveNow = monotonicTimestamp(
                    requested: now,
                    record: record,
                    slotCollections: [workspaceSlots, surfaceSlots],
                    sessionId: sessionId
                  ) else { continue }

            applyLifecycle(.restoring, to: &record, now: effectiveNow)
            record["workspaceId"] = request.workspaceId.uuidString
            record["surfaceId"] = request.surfaceId.uuidString

            var surfaceSlot = surfaceSlots[request.surfaceId.uuidString] as? [String: Any] ?? [:]
            surfaceSlots = slotsRemovingSession(sessionId, from: surfaceSlots)
            surfaceSlot["sessionId"] = sessionId
            surfaceSlot["updatedAt"] = effectiveNow
            surfaceSlots[request.surfaceId.uuidString] = surfaceSlot

            let ownedWorkspaceSlot = workspaceSlots.values.compactMap { value -> [String: Any]? in
                guard let slot = value as? [String: Any],
                      normalized(slot["sessionId"] as? String) == sessionId else {
                    return nil
                }
                return slot
            }.max {
                ($0["updatedAt"] as? TimeInterval ?? -.infinity)
                    < ($1["updatedAt"] as? TimeInterval ?? -.infinity)
            }
            if var workspaceSlot = ownedWorkspaceSlot {
                let targetWorkspaceAvailable = targetSlotIsAvailable(
                    workspaceSlots,
                    scopeId: request.workspaceId.uuidString,
                    sessionId: sessionId
                )
                workspaceSlots = slotsRemovingSession(sessionId, from: workspaceSlots)
                if targetWorkspaceAvailable {
                    workspaceSlot["sessionId"] = sessionId
                    workspaceSlot["updatedAt"] = effectiveNow
                    workspaceSlots[request.workspaceId.uuidString] = workspaceSlot
                }
            }
            sessions[sessionId] = record
            didMutate = true
        }
        guard didMutate else { return }
        root["sessions"] = sessions
        root["activeSessionsByWorkspace"] = workspaceSlots
        root["activeSessionsBySurface"] = surfaceSlots
        guard JSONSerialization.isValidJSONObject(root),
              let encoded = try? JSONSerialization.data(
                withJSONObject: root,
                options: [.prettyPrinted, .sortedKeys]
              ),
              replacePrivateStateFile(with: encoded, at: stateURL) else { return }
        markLegacySource(provider: provider, stateURL: stateURL)
    }

    func projectEstablishedHibernationToLegacy(
        provider: String,
        stateURL: URL,
        request: HibernatedResumeAuthorityRequest,
        legacyStampAtClaim: CmuxAgentSessionRegistry.LegacyStamp?,
        now: TimeInterval
    ) {
        guard let sessionId = normalized(request.agent.sessionId),
              let canonicalRecords = try? registry(
                provider: provider,
                stateURL: stateURL
              ).records(provider: provider, sessionIDs: [sessionId]),
              let canonical = canonicalRecords.first,
              let canonicalRecord = try? JSONSerialization.jsonObject(
                with: canonical.json
              ) as? [String: Any],
              lifecycleProjectionStillOwned(
                canonicalRecord,
                state: .hibernated,
                workspaceId: request.workspaceId,
                surfaceId: request.surfaceId
              ) else { return }

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
              var sessions = root["sessions"] as? [String: Any],
              var record = sessions[sessionId] as? [String: Any] else { return }
        let currentLegacyStamp = CmuxAgentSessionRegistry.LegacyStamp.read(path: stateURL.path)
        guard legacyStampAtClaim == currentLegacyStamp || recordBelongsToCurrentRuntime(record),
              record["restoreAuthority"] as? Bool != false,
              !hasCompletion(record),
              let recordUpdatedAt = record["updatedAt"] as? TimeInterval else { return }
        applyLifecycle(.hibernated, to: &record, now: max(now, recordUpdatedAt))
        sessions[sessionId] = record
        root["sessions"] = sessions
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
        surfaceId: String
    ) -> Bool {
        guard record["sessionState"] as? String == AgentSessionLifecycleState.hibernated.rawValue,
              record["restoreAuthority"] as? Bool != false,
              !hasCompletion(record),
              record["updatedAt"] is TimeInterval,
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

    /// Resume authority belongs to a concrete cmux process, not only to the
    /// stable workspace/surface UUIDs that session restore preserves. Both the
    /// root record and its active run must still name this process before cmux
    /// can queue provider resume input.
    private func recordBelongsToCurrentRuntime(_ record: [String: Any]) -> Bool {
        guard let currentRuntimeId = normalized(environment["CMUX_RUNTIME_ID"]),
              let runtime = record["cmuxRuntime"] as? [String: Any],
              normalized(runtime["id"] as? String) == currentRuntimeId else {
            return false
        }
        guard let activeRunId = normalized(record["activeRunId"] as? String) else {
            return true
        }
        guard let runs = record["runs"] as? [[String: Any]],
              let activeRun = runs.first(where: {
                  normalized($0["runId"] as? String) == activeRunId
              }),
              let activeRunRuntime = activeRun["cmuxRuntime"] as? [String: Any],
              normalized(activeRunRuntime["id"] as? String) == currentRuntimeId else {
            return false
        }
        return true
    }

    private func lifecycleProjectionStillOwned(
        _ record: [String: Any],
        state: AgentSessionLifecycleState,
        workspaceId: UUID,
        surfaceId: UUID
    ) -> Bool {
        guard record["sessionState"] as? String == state.rawValue,
              record["restoreAuthority"] as? Bool != false,
              !hasCompletion(record),
              recordBelongsToCurrentRuntime(record),
              let recordWorkspaceId = normalized(record["workspaceId"] as? String),
              let recordSurfaceId = normalized(record["surfaceId"] as? String) else {
            return false
        }
        return identifiersEqual(recordWorkspaceId, workspaceId.uuidString)
            && identifiersEqual(recordSurfaceId, surfaceId.uuidString)
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

    private func hasCompletion(_ record: [String: Any]) -> Bool {
        guard let completedAt = record["completedAt"] else { return false }
        return !(completedAt is NSNull)
    }

    private func targetSlotIsAvailable(
        _ slots: [String: Any],
        scopeId: String,
        sessionId: String
    ) -> Bool {
        guard let value = slots[scopeId] else { return true }
        guard let slot = value as? [String: Any],
              normalized(slot["sessionId"] as? String) == sessionId,
              slot["updatedAt"] is TimeInterval else {
            return false
        }
        return true
    }

    private func monotonicTimestamp(
        requested: TimeInterval,
        record: [String: Any],
        slotCollections: [[String: Any]],
        sessionId: String
    ) -> TimeInterval? {
        guard let recordUpdatedAt = record["updatedAt"] as? TimeInterval else { return nil }
        var effective = max(requested, recordUpdatedAt)
        for slots in slotCollections {
            for value in slots.values {
                guard let slot = value as? [String: Any],
                      normalized(slot["sessionId"] as? String) == sessionId else {
                    continue
                }
                guard let slotUpdatedAt = slot["updatedAt"] as? TimeInterval else { return nil }
                effective = max(effective, slotUpdatedAt)
            }
        }
        return effective
    }

    private func slotsRemovingSession(
        _ sessionId: String,
        from records: [String: Any]
    ) -> [String: Any] {
        var result = records
        for (key, value) in records {
            guard let record = value as? [String: Any],
                  normalized(record["sessionId"] as? String) == sessionId else {
                continue
            }
            result.removeValue(forKey: key)
        }
        return result
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
