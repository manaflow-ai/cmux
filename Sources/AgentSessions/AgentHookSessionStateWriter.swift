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

        func projectRestoredHibernationToLegacy(
            using writer: AgentHookSessionStateWriter,
            provider: String,
            stateURL: URL,
            sessionId: String,
            previousWorkspaceId: String?,
            previousSurfaceId: String,
            workspaceId: String,
            surfaceId: String,
            now: TimeInterval
        ) {
            writer.projectRestoredHibernationToLegacy(
                provider: provider,
                stateURL: stateURL,
                sessionId: sessionId,
                previousWorkspaceId: previousWorkspaceId,
                previousSurfaceId: previousSurfaceId,
                workspaceId: workspaceId,
                surfaceId: surfaceId,
                now: now
            )
        }

        func retryRestoredHibernation(
            using writer: AgentHookSessionStateWriter,
            provider: String,
            stateURL: URL,
            sessionId: String,
            previousWorkspaceId: String?,
            previousSurfaceId: String,
            workspaceId: String,
            surfaceId: String,
            now: TimeInterval
        ) async {
            let delays: [Duration] = [
                .zero,
                .milliseconds(25),
                .milliseconds(100),
                .milliseconds(500),
                .seconds(2),
            ]
            for delay in delays {
                if delay != .zero {
                    try? await Task.sleep(for: delay)
                }
                switch writer.adoptRestoredHibernationInRegistry(
                    provider: provider,
                    stateURL: stateURL,
                    sessionId: sessionId,
                    previousWorkspaceId: previousWorkspaceId,
                    previousSurfaceId: previousSurfaceId,
                    workspaceId: workspaceId,
                    surfaceId: surfaceId,
                    now: now,
                    busyTimeoutMilliseconds: 100,
                    importLegacyIfMissing: true
                ) {
                case .adopted:
                    writer.projectRestoredHibernationToLegacy(
                        provider: provider,
                        stateURL: stateURL,
                        sessionId: sessionId,
                        previousWorkspaceId: previousWorkspaceId,
                        previousSurfaceId: previousSurfaceId,
                        workspaceId: workspaceId,
                        surfaceId: surfaceId,
                        now: now
                    )
                    return
                case .rejected:
                    return
                case .retryable:
                    continue
                }
            }
        }
    }

    private static let writeCoordinator = WriteCoordinator()
    private enum RestoredHibernationAdoptionResult {
        case adopted
        case rejected
        case retryable
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
        AgentHookSessionStateWriter().recordRestoredHibernationSynchronously(
            kind: agent.kind,
            sessionId: agent.sessionId,
            previousWorkspaceId: previousWorkspaceId?.uuidString,
            previousSurfaceId: previousSurfaceId.uuidString,
            workspaceId: workspaceId.uuidString,
            surfaceId: surfaceId.uuidString
        )
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
        let normalizedSessionId = normalized(sessionId)
        let normalizedPreviousSurfaceId = normalized(previousSurfaceId)
        let normalizedWorkspaceId = normalized(workspaceId)
        let normalizedSurfaceId = normalized(surfaceId)
        guard let normalizedSessionId,
              let normalizedPreviousSurfaceId,
              let normalizedWorkspaceId,
              let normalizedSurfaceId else { return false }
        let stateURL = kind.hookStoreFileURL(
            homeDirectory: homeDirectory,
            environment: environment
        )
        let normalizedPreviousWorkspaceId = normalized(previousWorkspaceId)
        let adoption = adoptRestoredHibernationInRegistry(
            provider: kind.rawValue,
            stateURL: stateURL,
            sessionId: normalizedSessionId,
            previousWorkspaceId: normalizedPreviousWorkspaceId,
            previousSurfaceId: normalizedPreviousSurfaceId,
            workspaceId: normalizedWorkspaceId,
            surfaceId: normalizedSurfaceId,
            now: now,
            busyTimeoutMilliseconds: 25,
            importLegacyIfMissing: false
        )
        switch adoption {
        case .adopted:
            Task(priority: .utility) {
                await Self.writeCoordinator.projectRestoredHibernationToLegacy(
                    using: self,
                    provider: kind.rawValue,
                    stateURL: stateURL,
                    sessionId: normalizedSessionId,
                    previousWorkspaceId: normalizedPreviousWorkspaceId,
                    previousSurfaceId: normalizedPreviousSurfaceId,
                    workspaceId: normalizedWorkspaceId,
                    surfaceId: normalizedSurfaceId,
                    now: now
                )
            }
            return true
        case .rejected:
            return false
        case .retryable:
            Task(priority: .utility) {
                await Self.writeCoordinator.retryRestoredHibernation(
                    using: self,
                    provider: kind.rawValue,
                    stateURL: stateURL,
                    sessionId: normalizedSessionId,
                    previousWorkspaceId: normalizedPreviousWorkspaceId,
                    previousSurfaceId: normalizedPreviousSurfaceId,
                    workspaceId: normalizedWorkspaceId,
                    surfaceId: normalizedSurfaceId,
                    now: now
                )
            }
            return false
        }
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

    private func adoptRestoredHibernationInRegistry(
        provider: String,
        stateURL: URL,
        sessionId: String,
        previousWorkspaceId: String?,
        previousSurfaceId: String,
        workspaceId: String,
        surfaceId: String,
        now: TimeInterval,
        busyTimeoutMilliseconds: Int32,
        importLegacyIfMissing: Bool
    ) -> RestoredHibernationAdoptionResult {
        let registry = registry(
            provider: provider,
            stateURL: stateURL,
            busyTimeoutMilliseconds: busyTimeoutMilliseconds
        )
        let previousSlots = [
            previousWorkspaceId.map {
                CmuxAgentSessionRegistry.ActiveSlotKey(scope: .workspace, scopeID: $0)
            },
            CmuxAgentSessionRegistry.ActiveSlotKey(scope: .surface, scopeID: previousSurfaceId),
        ].compactMap { $0 }
        let activeSlots = [
            CmuxAgentSessionRegistry.ActiveSlotKey(scope: .workspace, scopeID: workspaceId),
            CmuxAgentSessionRegistry.ActiveSlotKey(scope: .surface, scopeID: surfaceId),
        ]
        let patch = {
            try registry.patchRecordRebindingActiveSlots(
                provider: provider,
                sessionID: sessionId,
                updatedAt: now,
                previousSlots: previousSlots,
                activeSlots: activeSlots,
                shouldMutate: { record in
                    restoredRecordCanBeAdopted(
                        record,
                        previousWorkspaceId: previousWorkspaceId,
                        previousSurfaceId: previousSurfaceId,
                        workspaceId: workspaceId,
                        surfaceId: surfaceId,
                        now: now
                    )
                }
            ) { record in
                applyRestoredHibernation(
                    to: &record,
                    workspaceId: workspaceId,
                    surfaceId: surfaceId,
                    now: now
                )
            }
        }
        do {
            switch try patch() {
            case .patched:
                return .adopted
            case .rejected:
                return .rejected
            case .recordMissing:
                guard importLegacyIfMissing else { return .retryable }
                _ = try registry.snapshotImportingLegacy(
                    provider: provider,
                    legacyURL: stateURL
                )
                switch try patch() {
                case .patched:
                    return .adopted
                case .rejected:
                    return .rejected
                case .recordMissing:
                    return .retryable
                }
            }
        } catch {
            return .retryable
        }
    }

    private func projectRestoredHibernationToLegacy(
        provider: String,
        stateURL: URL,
        sessionId: String,
        previousWorkspaceId: String?,
        previousSurfaceId: String,
        workspaceId: String,
        surfaceId: String,
        now: TimeInterval
    ) {
        let wroteLegacy = updateLegacyRecordNonblocking(stateURL: stateURL, sessionID: sessionId) { root, record in
            guard restoredRecordCanBeAdopted(
                record,
                previousWorkspaceId: previousWorkspaceId,
                previousSurfaceId: previousSurfaceId,
                workspaceId: workspaceId,
                surfaceId: surfaceId,
                now: now
            ) else { return false }
            applyRestoredHibernation(
                to: &record,
                workspaceId: workspaceId,
                surfaceId: surfaceId,
                now: now
            )
            root["activeSessionsByWorkspace"] = assigningSession(
                sessionId,
                to: workspaceId,
                now: now,
                in: root["activeSessionsByWorkspace"]
            )
            root["activeSessionsBySurface"] = assigningSession(
                sessionId,
                to: surfaceId,
                now: now,
                in: root["activeSessionsBySurface"]
            )
            return true
        }
        if wroteLegacy { markLegacySource(provider: provider, stateURL: stateURL) }
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
        guard let actualUpdatedAt = record["updatedAt"] as? TimeInterval,
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

    private func assigningSession(
        _ sessionId: String,
        to scopeId: String,
        now: TimeInterval,
        in value: Any?
    ) -> [String: Any] {
        guard var records = value as? [String: Any] else {
            return [scopeId: ["sessionId": sessionId, "updatedAt": now]]
        }
        var replacement: [String: Any]?
        var replacementUpdatedAt = -Double.infinity
        for (key, value) in records {
            guard let record = value as? [String: Any],
                  record["sessionId"] as? String == sessionId else { continue }
            let updatedAt = record["updatedAt"] as? TimeInterval ?? -Double.infinity
            if updatedAt >= replacementUpdatedAt {
                replacement = record
                replacementUpdatedAt = updatedAt
            }
            records.removeValue(forKey: key)
        }
        var activeRecord = replacement ?? [:]
        activeRecord["sessionId"] = sessionId
        activeRecord["updatedAt"] = now
        records[scopeId] = activeRecord
        return records
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
