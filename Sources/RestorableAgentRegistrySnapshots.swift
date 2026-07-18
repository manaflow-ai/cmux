import CmuxFoundation
import Foundation

extension RestorableAgentSessionIndex {
    /// Ensures the durable registry has seen the legacy providers referenced by
    /// persisted hibernation placeholders before any panel can adopt one. This
    /// only stats/parses those providers; it does not scan transcripts or the
    /// process table and does not materialize registry history.
    @discardableResult
    static func prepareAgentRegistryForSessionRestore(
        _ snapshot: inout AppSessionSnapshot,
        homeDirectory: String = NSHomeDirectory(),
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Set<RestorableAgentKind> {
        var kinds = Set<RestorableAgentKind>()
        var restoreOwners = Set<CmuxAgentSessionRegistry.RestoreOwnerContext>()
        for window in snapshot.windows.prefix(SessionPersistencePolicy.maxWindowsPerSnapshot) {
            for workspace in window.tabManager.workspaces.prefix(SessionPersistencePolicy.maxWorkspacesPerWindow) {
                for panel in workspace.panels.prefix(SessionPersistencePolicy.maxPanelsPerWorkspace) {
                    guard panel.terminal?.hibernation != nil,
                          let agent = panel.terminal?.agent else { continue }
                    let kind = agent.kind
                    kinds.insert(kind)
                    let sessionID = agent.sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let workspaceID = workspace.workspaceId, !sessionID.isEmpty {
                        restoreOwners.insert(.init(
                            provider: kind.rawValue,
                            sessionID: sessionID,
                            workspaceID: workspaceID.uuidString,
                            surfaceID: panel.id.uuidString
                        ))
                    }
                }
            }
        }
        guard !kinds.isEmpty else { return [] }

        let sources = kinds
            .sorted { $0.rawValue < $1.rawValue }
            .map {
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
        let failedProviders: Set<String>
        let verifiedCanonicalRestoreOwners: Set<CmuxAgentSessionRegistry.RestoreOwnerContext>
        do {
            let result = try registry.refreshLegacySources(
                sources,
                preservingCanonicalRestoreOwners: restoreOwners,
                fileManager: fileManager
            )
            failedProviders = result.failedProviders
            verifiedCanonicalRestoreOwners = result.verifiedCanonicalRestoreOwners
            if !failedProviders.isEmpty {
                NSLog(
                    "[SessionRestore] legacy agent registry preparation skipped providers=%@",
                    failedProviders.sorted().joined(separator: ",")
                )
            }
        } catch {
            NSLog("[SessionRestore] agent registry preparation unavailable error=%@", String(describing: error))
            failedProviders = Set(kinds.map(\.rawValue))
            verifiedCanonicalRestoreOwners = []
        }
        guard !failedProviders.isEmpty else { return [] }

        // Remove only the providers whose durable ownership could not be
        // verified. This makes every affected panel a plain shell before
        // construction, so one failed batch preflight cannot turn into one
        // SQLite busy wait per restored panel.
        for windowIndex in snapshot.windows.indices.prefix(SessionPersistencePolicy.maxWindowsPerSnapshot) {
            for workspaceIndex in snapshot.windows[windowIndex]
                .tabManager.workspaces.indices.prefix(SessionPersistencePolicy.maxWorkspacesPerWindow) {
                for panelIndex in snapshot.windows[windowIndex]
                    .tabManager.workspaces[workspaceIndex]
                    .panels.indices.prefix(SessionPersistencePolicy.maxPanelsPerWorkspace) {
                    guard var terminal = snapshot.windows[windowIndex]
                        .tabManager.workspaces[workspaceIndex]
                        .panels[panelIndex]
                        .terminal,
                        terminal.hibernation != nil,
                        let kind = terminal.agent?.kind,
                        failedProviders.contains(kind.rawValue) else { continue }
                    let sessionID = terminal.agent?.sessionId
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let owner = snapshot.windows[windowIndex]
                        .tabManager.workspaces[workspaceIndex]
                        .workspaceId.map {
                            CmuxAgentSessionRegistry.RestoreOwnerContext(
                                provider: kind.rawValue,
                                sessionID: sessionID,
                                workspaceID: $0.uuidString,
                                surfaceID: snapshot.windows[windowIndex]
                                    .tabManager.workspaces[workspaceIndex]
                                    .panels[panelIndex]
                                    .id.uuidString
                            )
                        }
                    if let owner, verifiedCanonicalRestoreOwners.contains(owner) {
                        continue
                    }
                    terminal.agent = nil
                    terminal.hibernation = nil
                    terminal.resumeBinding = nil
                    terminal.wasAgentRunning = false
                    snapshot.windows[windowIndex]
                        .tabManager.workspaces[workspaceIndex]
                        .panels[panelIndex]
                        .terminal = terminal
                }
            }
        }
        return Set(failedProviders.compactMap(RestorableAgentKind.init(rawValue:)))
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

    static func agentHookState(
        kind: RestorableAgentKind,
        fileURL: URL,
        snapshots: [String: CmuxAgentSessionRegistry.Snapshot]?,
        fileManager: FileManager,
        decoder: JSONDecoder
    ) -> RestorableAgentHookSessionStoreFile? {
        if let snapshot = snapshots?[kind.rawValue],
           let state = try? RestorableAgentHookSessionStoreFile.decode(
               snapshot: snapshot,
               decoder: decoder
           ) {
            return state
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
