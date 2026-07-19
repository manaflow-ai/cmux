import CmuxFoundation
import Foundation

extension RestorableAgentSessionIndex {
    private struct StartupRestoreCandidate {
        var workspaceIndex: Int
        var panelIndex: Int
        var workspaceID: UUID?
        var panelID: UUID
        var agent: SessionRestorableAgentSnapshot
        var wasHibernated: Bool

        var kind: RestorableAgentKind { agent.kind }
        var sessionID: String { agent.sessionId }
    }

    private struct DeadRestoringAttempt {
        var agent: SessionRestorableAgentSnapshot
        var provider: String
        var sessionID: String
        var workspaceID: UUID
        var panelID: UUID
        var attemptID: String
        var fingerprint: Data
        var updatedAt: TimeInterval
    }

    private struct StartupRegistryProjection {
        var recordsBySessionID: [String: CmuxAgentSessionRegistry.Record]
        var surfaceSlotsByID: [UUID: CmuxAgentSessionRegistry.ActiveSlot]
    }

    struct AgentRegistryHibernationSnapshotResult {
        var snapshots: [String: CmuxAgentSessionRegistry.Snapshot]
        var failedProviders: Set<String>
    }

    static let maximumHibernationRegistryProviders = 64
    static let maximumHibernationPanelContexts = 4_096
    static let maximumHibernationRegistryRecords = 12_288
    static let maximumHibernationRegistryBytes: Int64 = 64 * 1_024 * 1_024

    /// Reconciles all bounded workspace snapshots through one registry
    /// projection before the restore path can construct any terminal panels.
    @discardableResult
    static func prepareAgentRegistryForSessionRestore(
        _ snapshot: inout AppSessionSnapshot,
        homeDirectory: String = NSHomeDirectory(),
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Set<RestorableAgentKind> {
        var workspaceLocations: [(windowIndex: Int, workspaceIndex: Int)] = []
        var workspaces: [SessionWorkspaceSnapshot] = []
        for windowIndex in snapshot.windows.indices
            .prefix(SessionPersistencePolicy.maxWindowsPerSnapshot) {
            for workspaceIndex in snapshot.windows[windowIndex]
                .tabManager.workspaces.indices
                .prefix(SessionPersistencePolicy.maxWorkspacesPerWindow) {
                workspaceLocations.append((windowIndex, workspaceIndex))
                workspaces.append(
                    snapshot.windows[windowIndex].tabManager.workspaces[workspaceIndex]
                )
            }
        }
        let failures = prepareAgentRegistryForSessionRestore(
            &workspaces,
            homeDirectory: homeDirectory,
            fileManager: fileManager,
            environment: environment
        )
        for (offset, location) in workspaceLocations.enumerated() {
            snapshot.windows[location.windowIndex]
                .tabManager.workspaces[location.workspaceIndex] = workspaces[offset]
        }
        return failures
    }

    /// Reconciles one closed-history workspace through the same bounded
    /// projection used by full app-session restore.
    @discardableResult
    static func prepareAgentRegistryForSessionRestore(
        _ snapshot: inout SessionWorkspaceSnapshot,
        homeDirectory: String = NSHomeDirectory(),
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Set<RestorableAgentKind> {
        var workspaces = [snapshot]
        let failures = prepareAgentRegistryForSessionRestore(
            &workspaces,
            homeDirectory: homeDirectory,
            fileManager: fileManager,
            environment: environment
        )
        if let reconciled = workspaces.first {
            snapshot = reconciled
        }
        return failures
    }

    private static func prepareAgentRegistryForSessionRestore(
        _ workspaces: inout [SessionWorkspaceSnapshot],
        homeDirectory: String,
        fileManager: FileManager,
        environment: [String: String]
    ) -> Set<RestorableAgentKind> {
        var candidates: [StartupRestoreCandidate] = []
        var kinds = Set<RestorableAgentKind>()
        var restoreOwners = Set<CmuxAgentSessionRegistry.RestoreOwnerContext>()
        for workspaceIndex in workspaces.indices {
            for panelIndex in workspaces[workspaceIndex].panels.indices
                .prefix(SessionPersistencePolicy.maxPanelsPerWorkspace) {
                let panel = workspaces[workspaceIndex].panels[panelIndex]
                guard let terminal = panel.terminal,
                      let agent = terminal.agent else { continue }
                let sessionID = agent.sessionId
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !sessionID.isEmpty else { continue }
                kinds.insert(agent.kind)
                var normalizedAgent = agent
                normalizedAgent.sessionId = sessionID
                let candidate = StartupRestoreCandidate(
                    workspaceIndex: workspaceIndex,
                    panelIndex: panelIndex,
                    workspaceID: workspaces[workspaceIndex].workspaceId,
                    panelID: panel.id,
                    agent: normalizedAgent,
                    wasHibernated: terminal.hibernation != nil
                )
                candidates.append(candidate)
                if let workspaceID = candidate.workspaceID {
                    restoreOwners.insert(.init(
                        provider: candidate.kind.rawValue,
                        sessionID: candidate.sessionID,
                        workspaceID: workspaceID.uuidString,
                        surfaceID: candidate.panelID.uuidString
                    ))
                }
            }
        }
        guard !candidates.isEmpty else { return [] }
        guard candidates.count <= maximumHibernationPanelContexts,
              kinds.count <= maximumHibernationRegistryProviders else {
            suppressAutomaticStartup(for: candidates, in: &workspaces)
            return kinds
        }

        let orderedKinds = kinds.sorted { $0.rawValue < $1.rawValue }
        let sources = orderedKinds.map {
            CmuxAgentSessionRegistry.LegacySource(
                provider: $0.rawValue,
                url: $0.hookStoreFileURL(
                    homeDirectory: homeDirectory,
                    environment: environment
                )
            )
        }
        let registry = CmuxAgentSessionRegistry(
            url: CmuxAgentSessionRegistry.defaultURL(
                homeDirectory: homeDirectory,
                environment: environment
            ),
            busyTimeoutMilliseconds: 25
        )
        var failedProviders: Set<String>
        let verifiedCanonicalRestoreOwners: Set<CmuxAgentSessionRegistry.RestoreOwnerContext>
        let registryProjectionAvailable: Bool
        do {
            let refresh = try registry.refreshLegacySources(
                sources,
                preservingCanonicalRestoreOwners: restoreOwners,
                fileManager: fileManager
            )
            failedProviders = refresh.failedProviders
            verifiedCanonicalRestoreOwners = refresh.verifiedCanonicalRestoreOwners
            registryProjectionAvailable = true
        } catch {
            failedProviders = Set(kinds.map(\.rawValue))
            verifiedCanonicalRestoreOwners = []
            registryProjectionAvailable = false
        }

        let candidatesByProvider = Dictionary(grouping: candidates) {
            $0.kind.rawValue
        }
        var projections: [String: StartupRegistryProjection] = [:]
        var remainingRecords = maximumHibernationRegistryRecords
        var remainingBytes = maximumHibernationRegistryBytes
        for kind in orderedKinds where registryProjectionAvailable {
            let provider = kind.rawValue
            let providerCandidates = candidatesByProvider[provider] ?? []
            let panelContexts = Set(providerCandidates.compactMap { candidate in
                candidate.workspaceID.map {
                    CmuxAgentSessionRegistry.HookHibernationPanelContext(
                        workspaceID: $0.uuidString,
                        surfaceID: candidate.panelID.uuidString
                    )
                }
            })
            do {
                let projection = try registry.hookHibernationSnapshot(
                    provider: provider,
                    panelContexts: panelContexts,
                    exactSessionIDs: Set(providerCandidates.map { $0.sessionID }),
                    maximumRecords: remainingRecords,
                    maximumBytes: remainingBytes
                )
                let bytes = try projectedRegistryBytes(projection)
                remainingRecords -= projection.records.count
                remainingBytes -= bytes
                projections[provider] = StartupRegistryProjection(
                    recordsBySessionID: Dictionary(
                        projection.records.map { ($0.sessionID, $0) },
                        uniquingKeysWith: { current, replacement in
                            current.updatedAt >= replacement.updatedAt
                                ? current
                                : replacement
                        }
                    ),
                    surfaceSlotsByID: Dictionary(
                        projection.activeSlots.compactMap { slot in
                            guard slot.scope == .surface,
                                  let surfaceID = normalizedRegistryUUID(slot.scopeID) else {
                                return nil
                            }
                            return (surfaceID, slot)
                        },
                        uniquingKeysWith: { current, replacement in
                            current.updatedAt >= replacement.updatedAt
                                ? current
                                : replacement
                        }
                    )
                )
            } catch {
                failedProviders.insert(provider)
            }
        }

        var runtimeOwnershipProbe = AgentRuntimeOwnershipProbe(
            environment: environment,
            currentSocketStateResolver: {
                AgentHookRuntimeSocketState.resolve(preferredPath: $0)
            },
            processIdentityResolver: { AgentPIDProcessIdentity(pid: $0) }
        )
        var deadRestoringAttempts: [DeadRestoringAttempt] = []
        var reconciledCanonicalOwners = Set<
            CmuxAgentSessionRegistry.RestoreOwnerContext
        >()
        for candidate in candidates {
            guard let workspaceID = candidate.workspaceID else {
                rejectStartupRestoreCandidate(candidate, in: &workspaces)
                continue
            }
            guard let projection = projections[candidate.kind.rawValue] else {
                continue
            }
            guard let record = projection.recordsBySessionID[candidate.sessionID] else {
                rejectStartupRestoreCandidate(candidate, in: &workspaces)
                continue
            }
            guard let recordObject = try? JSONSerialization.jsonObject(
                with: record.json
            ) as? [String: Any] else {
                rejectStartupRestoreCandidate(candidate, in: &workspaces)
                continue
            }
            let projectedRestoreAuthority = CmuxAgentSessionRunAuthorityProjection()
                .projectedRestoreAuthority(recordJSON: record.json)
            guard projectedRestoreAuthority == true else {
                rejectStartupRestoreCandidate(candidate, in: &workspaces)
                continue
            }
            guard startupRecord(
                recordObject,
                projectedRestoreAuthority: projectedRestoreAuthority == true,
                matches: candidate,
                workspaceID: workspaceID
            ), startupRecordHasCanonicalSurfaceAuthority(
                recordObject,
                projection: projection,
                candidate: candidate
            ) else {
                rejectStartupRestoreCandidate(candidate, in: &workspaces)
                continue
            }
            let lifecycleValue = recordObject["sessionState"]
            let lifecycle: String?
            if lifecycleValue == nil || lifecycleValue is NSNull {
                lifecycle = nil
            } else if let lifecycleValue = lifecycleValue as? String {
                lifecycle = lifecycleValue
            } else {
                rejectStartupRestoreCandidate(candidate, in: &workspaces)
                continue
            }
            if lifecycle == nil
                || lifecycle == AgentSessionLifecycleState.active.rawValue {
                if candidate.wasHibernated {
                    rejectStartupRestoreCandidate(candidate, in: &workspaces)
                }
                continue
            }
            guard lifecycle == AgentSessionLifecycleState.hibernated.rawValue
                    || lifecycle == AgentSessionLifecycleState.restoring.rawValue else {
                rejectStartupRestoreCandidate(candidate, in: &workspaces)
                continue
            }
            reconciledCanonicalOwners.insert(.init(
                provider: candidate.kind.rawValue,
                sessionID: candidate.sessionID,
                workspaceID: workspaceID.uuidString,
                surfaceID: candidate.panelID.uuidString
            ))

            if lifecycle == AgentSessionLifecycleState.restoring.rawValue,
               runtimeOwnershipProbe.evidence(for: recordObject) == .provablyDeadForeign,
               let attemptID = normalizedRegistryValue(
                   recordObject["cmuxHibernationResumeAttemptId"] as? String
               ),
               let fingerprint = startupRecordFingerprint(recordObject) {
                deadRestoringAttempts.append(DeadRestoringAttempt(
                    agent: candidate.agent,
                    provider: candidate.kind.rawValue,
                    sessionID: candidate.sessionID,
                    workspaceID: workspaceID,
                    panelID: candidate.panelID,
                    attemptID: attemptID,
                    fingerprint: fingerprint,
                    updatedAt: record.updatedAt
                ))
            }

            var terminal = workspaces[candidate.workspaceIndex]
                .panels[candidate.panelIndex].terminal
            let hibernatedAt = registryTimeInterval(
                recordObject["cmuxHibernatedAt"]
            ) ?? record.updatedAt
            let lastActivityAt = terminal?.hibernation?.lastActivityAt ?? hibernatedAt
            terminal?.hibernation = SessionAgentHibernationSnapshot(
                hibernatedAt: hibernatedAt,
                lastActivityAt: lastActivityAt
            )
            terminal?.agent = candidate.agent
            terminal?.wasAgentRunning = false
            workspaces[candidate.workspaceIndex]
                .panels[candidate.panelIndex].terminal = terminal
        }

        normalizeProvablyDeadRestoringAttempts(
            deadRestoringAttempts,
            registry: registry
        )

        for candidate in candidates where failedProviders.contains(candidate.kind.rawValue) {
            guard var terminal = workspaces[candidate.workspaceIndex]
                .panels[candidate.panelIndex].terminal else { continue }
            if candidate.wasHibernated {
                let owner = candidate.workspaceID.map {
                    CmuxAgentSessionRegistry.RestoreOwnerContext(
                        provider: candidate.kind.rawValue,
                        sessionID: candidate.sessionID,
                        workspaceID: $0.uuidString,
                        surfaceID: candidate.panelID.uuidString
                    )
                }
                guard owner.map({
                    verifiedCanonicalRestoreOwners.contains($0)
                        || reconciledCanonicalOwners.contains($0)
                }) != true else {
                    continue
                }
                terminal.agent = nil
                terminal.hibernation = nil
                terminal.resumeBinding = nil
            }
            terminal.wasAgentRunning = false
            workspaces[candidate.workspaceIndex]
                .panels[candidate.panelIndex].terminal = terminal
        }
        return Set(failedProviders.compactMap(RestorableAgentKind.init(rawValue:)))
    }

    private static func rejectStartupRestoreCandidate(
        _ candidate: StartupRestoreCandidate,
        in workspaces: inout [SessionWorkspaceSnapshot]
    ) {
        guard var terminal = workspaces[candidate.workspaceIndex]
            .panels[candidate.panelIndex].terminal else { return }
        terminal.agent = nil
        terminal.hibernation = nil
        terminal.resumeBinding = nil
        terminal.wasAgentRunning = false
        workspaces[candidate.workspaceIndex]
            .panels[candidate.panelIndex].terminal = terminal
    }

    private static func suppressAutomaticStartup(
        for candidates: [StartupRestoreCandidate],
        in workspaces: inout [SessionWorkspaceSnapshot]
    ) {
        for candidate in candidates {
            workspaces[candidate.workspaceIndex]
                .panels[candidate.panelIndex].terminal?.wasAgentRunning = false
        }
    }

    private static func projectedRegistryBytes(
        _ snapshot: CmuxAgentSessionRegistry.Snapshot
    ) throws -> Int64 {
        var bytes: Int64 = 0
        for count in snapshot.records.map({ $0.json.count })
            + snapshot.activeSlots.map({ $0.json.count }) {
            let next = bytes.addingReportingOverflow(Int64(count))
            guard !next.overflow else { throw CocoaError(.fileReadTooLarge) }
            bytes = next.partialValue
        }
        return bytes
    }

    private static func startupRecord(
        _ record: [String: Any],
        projectedRestoreAuthority: Bool,
        matches candidate: StartupRestoreCandidate,
        workspaceID: UUID
    ) -> Bool {
        guard record["sessionId"] as? String == candidate.sessionID,
              projectedRestoreAuthority,
              record["updatedAt"] is NSNumber,
              normalizedRegistryUUID(record["workspaceId"] as? String) == workspaceID,
              normalizedRegistryUUID(record["surfaceId"] as? String) == candidate.panelID else {
            return false
        }
        guard let completedAt = record["completedAt"] else { return true }
        return completedAt is NSNull
    }

    private static func startupRecordHasCanonicalSurfaceAuthority(
        _ record: [String: Any],
        projection: StartupRegistryProjection,
        candidate: StartupRestoreCandidate
    ) -> Bool {
        if let slot = projection.surfaceSlotsByID[candidate.panelID] {
            guard slot.sessionID == candidate.sessionID,
                  let slotObject = try? JSONSerialization.jsonObject(
                      with: slot.json
                  ) as? [String: Any] else {
                return false
            }
            return slotObject["sessionId"] as? String == candidate.sessionID
                && slotObject["updatedAt"] is NSNumber
        }
        return record["cmuxHibernationDetached"] as? Bool == true
            && record["sessionState"] as? String
                == AgentSessionLifecycleState.hibernated.rawValue
    }

    private static func normalizeProvablyDeadRestoringAttempts(
        _ attempts: [DeadRestoringAttempt],
        registry: CmuxAgentSessionRegistry
    ) {
        for (provider, providerAttempts) in Dictionary(
            grouping: attempts,
            by: { $0.provider }
        ).sorted(by: { $0.key < $1.key }) {
            var normalizedAgent: SessionRestorableAgentSnapshot?
            do {
                try registry.withRecordRebindBatch { batch in
                    for attempt in providerAttempts {
                        let result = try batch.patchRecordRebindingActiveSlots(
                            provider: provider,
                            sessionID: attempt.sessionID,
                            updatedAt: attempt.updatedAt,
                            previousSlots: [],
                            activeSlots: [.init(
                                scope: .surface,
                                scopeID: attempt.panelID.uuidString
                            )],
                            requireExistingActiveSlots: true,
                            monotonicUpdatedAt: true,
                            shouldMutate: { record in
                                startupRecordFingerprint(record) == attempt.fingerprint
                                    && normalizedRegistryValue(
                                        record["cmuxHibernationResumeAttemptId"] as? String
                                    ) == attempt.attemptID
                                    && record["sessionState"] as? String
                                        == AgentSessionLifecycleState.restoring.rawValue
                                    && normalizedRegistryUUID(
                                        record["workspaceId"] as? String
                                    ) == attempt.workspaceID
                                    && normalizedRegistryUUID(
                                        record["surfaceId"] as? String
                                    ) == attempt.panelID
                            }
                        ) { record in
                            record["sessionState"] = AgentSessionLifecycleState.hibernated.rawValue
                            record.removeValue(forKey: "cmuxHibernationResumeAttemptId")
                            record.removeValue(forKey: "cmuxHibernationResumeStartedAt")
                            record.removeValue(forKey: "cmuxHibernationResumeFromAttemptId")
                        }
                        if result == .patched, normalizedAgent == nil {
                            normalizedAgent = attempt.agent
                        }
                    }
                }
            } catch {
                continue
            }
            if let agent = normalizedAgent {
                AgentHookSessionStateWriter.projectCanonicalLegacy(agent: agent)
            }
        }
    }

    private static func startupRecordFingerprint(
        _ record: [String: Any]
    ) -> Data? {
        guard JSONSerialization.isValidJSONObject(record) else { return nil }
        return try? JSONSerialization.data(
            withJSONObject: record,
            options: [.sortedKeys]
        )
    }

    private static func normalizedRegistryValue(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private static func normalizedRegistryUUID(_ value: String?) -> UUID? {
        normalizedRegistryValue(value).flatMap(UUID.init(uuidString:))
    }

    private static func registryTimeInterval(_ value: Any?) -> TimeInterval? {
        (value as? NSNumber)?.doubleValue
    }

    static func agentRegistrySnapshots(
        _ sources: [(kind: RestorableAgentKind, fileURL: URL)],
        fileManager: FileManager,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: CmuxAgentSessionRegistry.Snapshot]? {
        guard let firstSource = sources.first else {
            return nil
        }
        let registryURL: URL
        if let explicit = environment["CMUX_AGENT_SESSION_REGISTRY_PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !explicit.isEmpty {
            registryURL = URL(fileURLWithPath: NSString(string: explicit).expandingTildeInPath)
        } else {
            registryURL = firstSource.fileURL.deletingLastPathComponent()
                .appendingPathComponent(CmuxAgentSessionRegistry.filename, isDirectory: false)
        }
        let registry = CmuxAgentSessionRegistry(url: registryURL)
        let legacySources = sources.map {
            CmuxAgentSessionRegistry.LegacySource(provider: $0.kind.rawValue, url: $0.fileURL)
        }
        do {
            return try registry.snapshotsImportingLegacy(
                sources: legacySources,
                fileManager: fileManager
            )
        } catch {
            var recovered: [String: CmuxAgentSessionRegistry.Snapshot] = [:]
            for source in legacySources {
                recovered[source.provider] = (try? registry.snapshotImportingLegacy(
                    provider: source.provider,
                    legacyURL: source.url,
                    fileManager: fileManager
                )) ?? (try? registry.snapshot(provider: source.provider))
            }
            return recovered.isEmpty ? nil : recovered
        }
    }

    /// Refreshes compatibility sources, then materializes only the active slot
    /// owners for open panels and exact process-detected session identities.
    /// Every failure produces an explicit empty provider snapshot so callers do
    /// not fall back to full registry history or compatibility JSON.
    static func agentRegistryHibernationSnapshots(
        _ sources: [(kind: RestorableAgentKind, fileURL: URL)],
        panelKeys: Set<PanelKey>,
        exactSessionIDsByProvider: [String: Set<String>],
        maximumProviders: Int = maximumHibernationRegistryProviders,
        maximumPanelContexts: Int = maximumHibernationPanelContexts,
        maximumRecords: Int = maximumHibernationRegistryRecords,
        maximumBytes: Int64 = maximumHibernationRegistryBytes,
        maximumLegacySourceReadBytes: Int64 = CmuxAgentSessionRegistry.maximumLegacyRefreshReadBytes,
        fileManager: FileManager,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> AgentRegistryHibernationSnapshotResult {
        let uniqueSources = Dictionary(
            sources.map { ($0.kind.rawValue, $0) },
            uniquingKeysWith: { _, latest in latest }
        ).values.sorted { $0.kind.rawValue < $1.kind.rawValue }
        let emptySnapshots = Dictionary(uniqueKeysWithValues: uniqueSources.map {
            ($0.kind.rawValue, CmuxAgentSessionRegistry.Snapshot(records: [], activeSlots: []))
        })
        let allProviders = Set(uniqueSources.map { $0.kind.rawValue })
        guard !uniqueSources.isEmpty else {
            return AgentRegistryHibernationSnapshotResult(snapshots: [:], failedProviders: [])
        }
        guard panelKeys.count <= max(0, maximumPanelContexts),
              maximumRecords >= 0,
              maximumBytes >= 0,
              maximumLegacySourceReadBytes >= 0 else {
            return AgentRegistryHibernationSnapshotResult(
                snapshots: emptySnapshots,
                failedProviders: allProviders
            )
        }

        let firstSource = uniqueSources[0]
        let registryURL: URL
        if let explicit = environment["CMUX_AGENT_SESSION_REGISTRY_PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !explicit.isEmpty {
            registryURL = URL(fileURLWithPath: NSString(string: explicit).expandingTildeInPath)
        } else {
            registryURL = firstSource.fileURL.deletingLastPathComponent()
                .appendingPathComponent(CmuxAgentSessionRegistry.filename, isDirectory: false)
        }
        let registry = CmuxAgentSessionRegistry(url: registryURL)
        let legacySources = uniqueSources.map {
            CmuxAgentSessionRegistry.LegacySource(provider: $0.kind.rawValue, url: $0.fileURL)
        }
        let panelContexts = Set(panelKeys.map {
            CmuxAgentSessionRegistry.HookHibernationPanelContext(
                workspaceID: $0.workspaceId.uuidString,
                surfaceID: $0.panelId.uuidString
            )
        })
        let exactProviders = Set(exactSessionIDsByProvider.compactMap { entry in
            allProviders.contains(entry.key) && !entry.value.isEmpty ? entry.key : nil
        })
        let panelOwnerProviders: Set<String>
        do {
            panelOwnerProviders = try registry.hookHibernationPanelOwnerProviders(
                providers: allProviders,
                panelContexts: panelContexts
            )
        } catch {
            return AgentRegistryHibernationSnapshotResult(
                snapshots: emptySnapshots,
                failedProviders: allProviders
            )
        }
        // Exact process evidence is strongest and consumes the bounded legacy
        // read budget first. Existing panel owners follow; speculative adapters
        // are admitted only from whatever budget remains.
        let priorityProviders = exactProviders.sorted()
            + panelOwnerProviders.subtracting(exactProviders).sorted()
        let refresh: CmuxAgentSessionRegistry.LegacyRefreshResult
        do {
            refresh = try registry.refreshLegacySources(
                legacySources,
                prioritizingProviders: priorityProviders,
                maximumReadBytes: maximumLegacySourceReadBytes,
                fileManager: fileManager
            )
        } catch {
            return AgentRegistryHibernationSnapshotResult(
                snapshots: emptySnapshots,
                failedProviders: allProviders
            )
        }

        var snapshots = emptySnapshots
        var failedProviders = refresh.failedProviders
        do {
            let availableProviders = allProviders.subtracting(failedProviders)
            let selected = try registry.hookHibernationSnapshots(
                providers: availableProviders,
                panelContexts: panelContexts,
                exactSessionIDsByProvider: exactSessionIDsByProvider,
                maximumProviders: maximumProviders,
                maximumRecords: maximumRecords,
                maximumBytes: maximumBytes
            )
            snapshots.merge(selected.snapshots) { _, selected in selected }
            failedProviders.formUnion(selected.failedProviders)
        } catch {
            return AgentRegistryHibernationSnapshotResult(
                snapshots: emptySnapshots,
                failedProviders: allProviders
            )
        }
        return AgentRegistryHibernationSnapshotResult(
            snapshots: snapshots,
            failedProviders: failedProviders
        )
    }

    static func agentHookState(
        kind: RestorableAgentKind,
        fileURL: URL,
        snapshots: [String: CmuxAgentSessionRegistry.Snapshot]?,
        fileManager: FileManager,
        decoder: JSONDecoder
    ) -> RestorableAgentHookSessionStoreFile? {
        if let snapshot = snapshots?[kind.rawValue] {
            return try? RestorableAgentHookSessionStoreFile.decode(
                snapshot: snapshot,
                decoder: decoder
            )
        }
        return RestorableAgentHookSessionStoreFile.load(
            provider: kind.rawValue,
            legacyURL: fileURL,
            environment: ProcessInfo.processInfo.environment,
            fileManager: fileManager,
            decoder: decoder
        )
    }
}

/// Shared canonical reader for app surfaces that consume hook-session state.
/// SQLite is authoritative and retains the full history; bounded legacy JSON
/// remains a compatibility fallback for stores written before the registry.
enum AgentHookSessionRegistryReader {
    struct RecordData: Sendable {
        let sessionID: String
        let updatedAt: TimeInterval
        let data: Data
    }

    private static let maximumSessionIdentifierBytes = 16 * 1_024

    static func legacyURL(
        provider: String,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        guard CmuxVaultAgentRegistration.isValidID(provider) else { return nil }
        let directory: URL
        if let override = normalized(environment["CMUX_AGENT_HOOK_STATE_DIR"]) {
            directory = URL(
                fileURLWithPath: NSString(string: override).expandingTildeInPath,
                isDirectory: true
            )
        } else {
            directory = homeDirectory.appendingPathComponent(".cmuxterm", isDirectory: true)
        }
        return directory.appendingPathComponent("\(provider)-hook-sessions.json", isDirectory: false)
    }

    static func recordData(
        provider: String,
        sessionID: String,
        legacyURL: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> Data? {
        guard CmuxVaultAgentRegistration.isValidID(provider),
              !sessionID.isEmpty,
              sessionID.utf8.count <= maximumSessionIdentifierBytes else {
            return nil
        }
        let registry = registry(legacyURL: legacyURL, environment: environment)
        let existingRecord = try? registry.hookRecord(
            provider: provider,
            sessionID: sessionID
        )
        if let existingRecord,
           existingRecord.writerGeneration > 0 {
            return existingRecord.json
        }

        // Generation-zero rows came from compatibility JSON. Refresh its
        // stamp before returning one so a concurrently running older cmux can
        // update the same session without this app serving stale bindings.
        let refresh = try? registry.refreshLegacySources(
            [.init(provider: provider, url: legacyURL)],
            fileManager: fileManager
        )
        if let record = try? registry.hookRecord(provider: provider, sessionID: sessionID) {
            return record.json
        }
        if refresh?.failedProviders.contains(provider) == false {
            // A successful refresh can legitimately delete a generation-zero
            // row that disappeared from an older writer's complete store.
            return nil
        }
        if let existingRecord {
            return existingRecord.json
        }
        return legacyRecords(
            registry: registry,
            legacyURL: legacyURL,
            fileManager: fileManager
        )?[sessionID]
    }

    static func records(
        provider: String,
        legacyURL: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        maximumRecords: Int = 20_000
    ) -> [String: Data]? {
        guard CmuxVaultAgentRegistration.isValidID(provider) else { return nil }
        let registry = registry(legacyURL: legacyURL, environment: environment)
        let refresh = try? registry.refreshLegacySources(
            [.init(provider: provider, url: legacyURL)],
            fileManager: fileManager
        )
        if let snapshot = try? registry.hookBoundedSnapshot(
            provider: provider,
            maximumRecords: maximumRecords
        ), !snapshot.records.isEmpty || refresh?.failedProviders.contains(provider) == false {
            var result: [String: Data] = [:]
            result.reserveCapacity(snapshot.records.count)
            for record in snapshot.records {
                result[record.sessionID] = record.json
            }
            return result
        }
        return legacyRecords(
            registry: registry,
            legacyURL: legacyURL,
            fileManager: fileManager
        )
    }

    /// Reads active owners plus bounded recent history without materializing
    /// the provider's full canonical store. Exact lookups remain available for
    /// older rows omitted from this seed-oriented view.
    static func recentRecordData(
        provider: String,
        legacyURL: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        maximumRecords: Int,
        maximumBytes: Int64
    ) -> [RecordData]? {
        guard CmuxVaultAgentRegistration.isValidID(provider) else { return nil }
        let registry = registry(legacyURL: legacyURL, environment: environment)
        let refresh = try? registry.refreshLegacySources(
            [.init(provider: provider, url: legacyURL)],
            fileManager: fileManager
        )
        do {
            let records = try registry.hookBoundedRecentRecords(
                provider: provider,
                maximumRecords: maximumRecords,
                maximumBytes: maximumBytes
            )
            if !records.isEmpty || refresh?.failedProviders.contains(provider) == false {
                return records.map {
                    RecordData(sessionID: $0.sessionID, updatedAt: $0.updatedAt, data: $0.json)
                }
            }
        } catch {
            // A populated canonical store that exceeds the caller's seed
            // budget must fail closed. Falling back to its compatibility
            // projection could silently omit active owners.
            if let metrics = try? registry.hookStorageMetrics(provider: provider),
               metrics.recordCount > 0 {
                return nil
            }
        }

        guard let legacy = legacyRecords(
            registry: registry,
            legacyURL: legacyURL,
            fileManager: fileManager
        ) else { return nil }
        let ordered = legacy.map { sessionID, data -> RecordData in
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            return RecordData(
                sessionID: sessionID,
                updatedAt: object?["updatedAt"] as? TimeInterval ?? 0,
                data: data
            )
        }.sorted {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.sessionID < $1.sessionID
        }

        let recordLimit = max(0, maximumRecords)
        let byteLimit = max(0, maximumBytes)
        var selected: [RecordData] = []
        selected.reserveCapacity(min(recordLimit, ordered.count))
        var selectedBytes: Int64 = 0
        for record in ordered.prefix(recordLimit) {
            let nextBytes = selectedBytes.addingReportingOverflow(Int64(record.data.count))
            guard !nextBytes.overflow, nextBytes.partialValue <= byteLimit else { break }
            selectedBytes = nextBytes.partialValue
            selected.append(record)
        }
        return selected
    }

    private static func registry(
        legacyURL: URL,
        environment: [String: String]
    ) -> CmuxAgentSessionRegistry {
        let registryURL: URL
        if let explicit = normalized(environment["CMUX_AGENT_SESSION_REGISTRY_PATH"]) {
            registryURL = URL(fileURLWithPath: NSString(string: explicit).expandingTildeInPath)
        } else {
            registryURL = legacyURL.deletingLastPathComponent()
                .appendingPathComponent(CmuxAgentSessionRegistry.filename, isDirectory: false)
        }
        return CmuxAgentSessionRegistry(url: registryURL)
    }

    private static func legacyRecords(
        registry: CmuxAgentSessionRegistry,
        legacyURL: URL,
        fileManager: FileManager
    ) -> [String: Data]? {
        guard fileManager.fileExists(atPath: legacyURL.path),
              let data = try? registry.readHookLegacySourceData(at: legacyURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let sessions = (root["sessions"] as? [String: Any]) ?? root
        var result: [String: Data] = [:]
        result.reserveCapacity(sessions.count)
        for (sessionID, value) in sessions {
            guard JSONSerialization.isValidJSONObject(value),
                  let encoded = try? JSONSerialization.data(
                      withJSONObject: value,
                      options: [.sortedKeys]
                  ) else { continue }
            result[sessionID] = encoded
        }
        return result
    }

    private static func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}
