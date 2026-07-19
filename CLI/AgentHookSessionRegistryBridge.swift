import CmuxFoundation
import Foundation

struct AgentHookSessionStoreLoadWarning: Codable, Sendable, Equatable {
    enum Code: String, Codable, Sendable {
        case authoritativeSnapshotDecodeFailed = "authoritative_snapshot_decode_failed"
        case legacySourceImportFailed = "legacy_source_import_failed"
        case storageLimitExceeded = "storage_limit_exceeded"
    }

    enum Fallback: String, Codable, Sendable {
        case legacy
        case registry
    }

    var provider: String
    var path: String
    var code: Code
    var fallback: Fallback
}

struct AgentHookSessionStoreLoadResult {
    var store: ClaudeHookSessionStoreFile
    var warning: AgentHookSessionStoreLoadWarning?
}

struct AgentHookSessionRegistrySnapshots {
    var snapshots: [String: CmuxAgentSessionRegistry.Snapshot]
    var warnings: [AgentHookSessionStoreLoadWarning]
    var totalRecordCounts: [String: Int] = [:]
    var boundedValidationFailures: Set<String> = []
}

struct AgentHookSessionStoreLoadFailure: Error {
    enum Scope: String, Sendable {
        case registryRecord = "registry_record"
        case registryProvider = "registry_provider"
        case registryGraphNodes = "registry_graph_nodes"
        case providerMaterialization = "provider_materialization"
        case selectionMaterialization = "selection_materialization"
        case legacyFile = "legacy_file"
        case legacySessions = "legacy_sessions"
        case legacyGraphNodes = "legacy_graph_nodes"
        case legacyRecord = "legacy_record"
    }

    var provider: String
    var path: String
    var code: AgentHookSessionStoreLoadWarning.Code
    var scope: Scope? = nil
    var sessionID: String? = nil
    var observedBytes: Int64? = nil
    var maximumBytes: Int64? = nil
    var observedCount: Int64? = nil
    var maximumCount: Int64? = nil
    var canonicalPath: String? = nil
}

/// Converts provider-specific hook models to the shared row-oriented registry.
/// The bridge keeps legacy JSON as a compatibility projection while making the
/// registry authoritative for any row written by this schema generation.
struct AgentHookSessionRegistryBridge {
    enum MutationError: Error {
        case newerWriterGeneration
    }

    private static let maximumInspectionRecordBytes: Int64 = 4 * 1_024 * 1_024
    private static let maximumInspectionProviderBytes: Int64 = 64 * 1_024 * 1_024
    private static let maximumInspectionSelectionBytes: Int64 = 128 * 1_024 * 1_024
    private static let maximumLegacyFileBytes: Int64 = 64 * 1_024 * 1_024
    private static let maximumLegacySessions = 20_000
    private static let maximumLegacyGraphNodes = 20_000

    struct InspectionStorageLimits {
        var recordBytes: Int64
        var providerBytes: Int64
        var selectionBytes: Int64
        var legacyFileBytes: Int64

        static let production = InspectionStorageLimits(
            recordBytes: AgentHookSessionRegistryBridge.maximumInspectionRecordBytes,
            providerBytes: AgentHookSessionRegistryBridge.maximumInspectionProviderBytes,
            selectionBytes: AgentHookSessionRegistryBridge.maximumInspectionSelectionBytes,
            legacyFileBytes: AgentHookSessionRegistryBridge.maximumLegacyFileBytes
        )
    }

    typealias InspectionAdmissionLoader = (
        CmuxAgentSessionRegistry.LegacySource,
        CmuxAgentSessionRegistry.LegacyStamp,
        Int
    ) throws -> CmuxAgentSessionRegistry.HookLegacySourceAdmission

    struct InspectionSourcePreflight {
        var provider: String
        var registryPath: String
        var legacyPath: String
        var metrics: CmuxAgentSessionRegistry.HookStorageMetrics
        var legacyBytes: Int64
        var legacyMetrics: CmuxAgentSessionRegistry.HookLegacySourceMetrics? = nil
    }

    struct InspectionPreflightResult {
        var admissions: [CmuxAgentSessionRegistry.HookLegacySourceAdmission]
        var warnings: [AgentHookSessionStoreLoadWarning]
    }

    let provider: String
    let statePath: String
    let environment: [String: String]
    let fileManager: FileManager

    private var registry: CmuxAgentSessionRegistry {
        CmuxAgentSessionRegistry(url: registryURL)
    }

    private var registryURL: URL {
        if let explicit = normalized(environment["CMUX_AGENT_SESSION_REGISTRY_PATH"]) {
            return URL(fileURLWithPath: NSString(string: explicit).expandingTildeInPath)
        }
        if environment["CMUX_CLAUDE_HOOK_STATE_PATH"] != nil
            || environment["CMUX_AGENT_HOOK_STATE_DIR"] != nil {
            return URL(fileURLWithPath: statePath).deletingLastPathComponent()
                .appendingPathComponent(CmuxAgentSessionRegistry.filename, isDirectory: false)
        }
        return CmuxAgentSessionRegistry.defaultURL(environment: environment)
    }

    static func snapshots(
        specifications: [(provider: String, suffix: String)],
        stateDirectory: String,
        environment: [String: String],
        fileManager: FileManager,
        maximumLegacyGraphNodes: Int = AgentHookSessionRegistryBridge.maximumLegacyGraphNodes
    ) throws -> AgentHookSessionRegistrySnapshots {
        let registryURL: URL
        if let explicit = environment["CMUX_AGENT_SESSION_REGISTRY_PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !explicit.isEmpty {
            registryURL = URL(fileURLWithPath: NSString(string: explicit).expandingTildeInPath)
        } else {
            registryURL = URL(fileURLWithPath: stateDirectory, isDirectory: true)
                .appendingPathComponent(CmuxAgentSessionRegistry.filename, isDirectory: false)
        }
        let registry = CmuxAgentSessionRegistry(url: registryURL)
        let sources = specifications.map { specification in
            CmuxAgentSessionRegistry.LegacySource(
                provider: specification.provider,
                url: URL(fileURLWithPath: stateDirectory, isDirectory: true)
                    .appendingPathComponent("\(specification.suffix)-hook-sessions.json", isDirectory: false)
            )
        }.sorted { $0.provider < $1.provider }
        let preflight = try preflightInspectionSources(
            sources,
            registry: registry,
            registryPath: registryURL.path,
            fileManager: fileManager,
            maximumLegacyGraphNodes: max(0, maximumLegacyGraphNodes)
        )
        let admissions = preflight.admissions
        do {
            return AgentHookSessionRegistrySnapshots(
                snapshots: try registry.snapshotsImportingAdmittedLegacy(
                    sources: sources,
                    admissions: admissions,
                    maximumGraphNodes: max(0, maximumLegacyGraphNodes)
                ),
                warnings: preflight.warnings
            )
        } catch let error as CmuxAgentSessionRegistry.HookInspectionGraphUnionLimitError {
            throw inspectionGraphLoadFailure(error, registryPath: registryURL.path)
        } catch let error as CmuxAgentSessionRegistry.HookGraphNodeInspectionLimitError {
            throw inspectionGraphLoadFailure(error, registryPath: registryURL.path)
        } catch let error as CmuxAgentSessionRegistry.HookGraphNodeMalformedRecordError {
            throw inspectionGraphLoadFailure(error, registryPath: registryURL.path)
        } catch let error as CmuxAgentSessionRegistry.HookInspectionStorageLimitError {
            throw inspectionStorageLoadFailure(error, registryPath: registryURL.path)
        } catch {
            var recovered: [String: CmuxAgentSessionRegistry.Snapshot] = [:]
            var warnings = preflight.warnings
            for source in sources {
                do {
                    recovered[source.provider] = try registry.snapshotsImportingAdmittedLegacy(
                        sources: [source],
                        admissions: admissions.filter {
                            $0.source.provider == source.provider
                        },
                        maximumGraphNodes: max(0, maximumLegacyGraphNodes)
                    )[source.provider] ?? .init(records: [], activeSlots: [])
                } catch let error as CmuxAgentSessionRegistry.HookInspectionGraphUnionLimitError {
                    throw inspectionGraphLoadFailure(error, registryPath: registryURL.path)
                } catch let error as CmuxAgentSessionRegistry.HookGraphNodeInspectionLimitError {
                    throw inspectionGraphLoadFailure(error, registryPath: registryURL.path)
                } catch let error as CmuxAgentSessionRegistry.HookGraphNodeMalformedRecordError {
                    throw inspectionGraphLoadFailure(error, registryPath: registryURL.path)
                } catch let error as CmuxAgentSessionRegistry.HookInspectionStorageLimitError {
                    throw inspectionStorageLoadFailure(error, registryPath: registryURL.path)
                } catch {
                    guard let fallback = try? registry.snapshot(provider: source.provider),
                          !fallback.records.isEmpty else {
                        throw AgentHookSessionStoreLoadFailure(
                            provider: source.provider,
                            path: source.url.path,
                            code: .legacySourceImportFailed
                        )
                    }
                    let bridge = AgentHookSessionRegistryBridge(
                        provider: source.provider,
                        statePath: source.url.path,
                        environment: environment,
                        fileManager: fileManager
                    )
                    guard let validation = try? bridge.loadForInspection(snapshot: fallback),
                          validation.warning == nil,
                          !validation.store.sessions.isEmpty else {
                        throw AgentHookSessionStoreLoadFailure(
                            provider: source.provider,
                            path: source.url.path,
                            code: .legacySourceImportFailed
                        )
                    }
                    recovered[source.provider] = fallback
                    warnings.append(AgentHookSessionStoreLoadWarning(
                        provider: source.provider,
                        path: source.url.path,
                        code: .legacySourceImportFailed,
                        fallback: .registry
                    ))
                }
            }
            let consistent: [String: CmuxAgentSessionRegistry.Snapshot]
            do {
                consistent = try registry.snapshotsImportingAdmittedLegacy(
                    sources: sources,
                    admissions: [],
                    maximumGraphNodes: max(0, maximumLegacyGraphNodes)
                )
            } catch let error as CmuxAgentSessionRegistry.HookInspectionGraphUnionLimitError {
                throw inspectionGraphLoadFailure(error, registryPath: registryURL.path)
            } catch let error as CmuxAgentSessionRegistry.HookGraphNodeInspectionLimitError {
                throw inspectionGraphLoadFailure(error, registryPath: registryURL.path)
            } catch let error as CmuxAgentSessionRegistry.HookGraphNodeMalformedRecordError {
                throw inspectionGraphLoadFailure(error, registryPath: registryURL.path)
            } catch let error as CmuxAgentSessionRegistry.HookInspectionStorageLimitError {
                throw inspectionStorageLoadFailure(error, registryPath: registryURL.path)
            }
            return AgentHookSessionRegistrySnapshots(
                snapshots: consistent,
                warnings: warnings
            )
        }
    }

    /// Loads only the newest list candidates per provider while preserving the
    /// same legacy refresh, storage admission, and registry fallback behavior as
    /// the complete inspection path.
    static func boundedRecentSnapshotsForList(
        specifications: [(provider: String, suffix: String)],
        stateDirectory: String,
        environment: [String: String],
        fileManager: FileManager,
        maximumRecordsPerProvider: Int,
        maximumLegacyGraphNodes: Int = AgentHookSessionRegistryBridge.maximumLegacyGraphNodes
    ) throws -> AgentHookSessionRegistrySnapshots {
        let registryURL: URL
        if let explicit = environment["CMUX_AGENT_SESSION_REGISTRY_PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !explicit.isEmpty {
            registryURL = URL(fileURLWithPath: NSString(string: explicit).expandingTildeInPath)
        } else {
            registryURL = URL(fileURLWithPath: stateDirectory, isDirectory: true)
                .appendingPathComponent(CmuxAgentSessionRegistry.filename, isDirectory: false)
        }
        let registry = CmuxAgentSessionRegistry(url: registryURL)
        let sources = specifications.map { specification in
            CmuxAgentSessionRegistry.LegacySource(
                provider: specification.provider,
                url: URL(fileURLWithPath: stateDirectory, isDirectory: true)
                    .appendingPathComponent("\(specification.suffix)-hook-sessions.json", isDirectory: false)
            )
        }.sorted { $0.provider < $1.provider }
        let preflight = try preflightInspectionSources(
            sources,
            registry: registry,
            registryPath: registryURL.path,
            fileManager: fileManager,
            maximumLegacyGraphNodes: max(0, maximumLegacyGraphNodes)
        )
        let admissions = preflight.admissions
        let maximumRecordsPerProvider = max(0, maximumRecordsPerProvider)
        let decoder = JSONDecoder()
        let canonicalizer = AgentSessionRunCanonicalizer()
        func projectRecord(
            provider: String,
            stored: CmuxAgentSessionRegistry.Record
        ) throws -> CmuxAgentSessionRegistry.HookListOrderKey {
            do {
                let record = try decoder.decode(ClaudeHookSessionRecord.self, from: stored.json)
                guard record.sessionId == stored.sessionID else {
                    throw ProjectionError.recordIdentityMismatch
                }
                let run = canonicalizer.projectedRun(record: record, provider: provider)
                return CmuxAgentSessionRegistry.HookListOrderKey(
                    updatedAt: run.updatedAt,
                    sortValues: .init(
                        sessionID: record.sessionId,
                        agent: provider,
                        runID: run.runId,
                        workspaceID: record.workspaceId,
                        surfaceID: record.surfaceId,
                        identitySource: "hook_session",
                        pid: run.pid,
                        processStartedAt: run.processStartedAt
                    )
                )
            } catch {
                throw CmuxAgentSessionRegistry.HookListProjectionValidationError(
                    provider: provider
                )
            }
        }
        func validateActiveSlot(
            provider: String,
            stored: CmuxAgentSessionRegistry.ActiveSlot
        ) throws {
            do {
                let slot = try decoder.decode(
                    ClaudeHookActiveSessionRecord.self,
                    from: stored.json
                )
                guard slot.sessionId == stored.sessionID else {
                    throw ProjectionError.slotIdentityMismatch
                }
            } catch {
                throw CmuxAgentSessionRegistry.HookListProjectionValidationError(
                    provider: provider
                )
            }
        }
        do {
            let bounded = try registry.globallyBoundedRecentSnapshotsImportingAdmittedLegacy(
                sources: sources,
                admissions: admissions,
                maximumRecords: maximumRecordsPerProvider,
                maximumGraphNodes: max(0, maximumLegacyGraphNodes),
                projectRecord: projectRecord,
                validateActiveSlot: validateActiveSlot
            )
            return AgentHookSessionRegistrySnapshots(
                snapshots: bounded.mapValues(\.snapshot),
                warnings: preflight.warnings,
                totalRecordCounts: bounded.mapValues(\.totalRecordCount)
            )
        } catch let error as CmuxAgentSessionRegistry.HookInspectionGraphUnionLimitError {
            throw inspectionGraphLoadFailure(error, registryPath: registryURL.path)
        } catch let error as CmuxAgentSessionRegistry.HookGraphNodeInspectionLimitError {
            throw inspectionGraphLoadFailure(error, registryPath: registryURL.path)
        } catch let error as CmuxAgentSessionRegistry.HookGraphNodeMalformedRecordError {
            throw inspectionGraphLoadFailure(error, registryPath: registryURL.path)
        } catch let error as CmuxAgentSessionRegistry.HookInspectionStorageLimitError {
            throw inspectionStorageLoadFailure(error, registryPath: registryURL.path)
        } catch {
            guard error is CmuxAgentSessionRegistry.HookListProjectionValidationError
                    || error is CmuxAgentSessionRegistry.HookLegacySourceImportError else {
                throw error
            }
            var recovered: [String: CmuxAgentSessionRegistry.Snapshot] = [:]
            var totalRecordCounts: [String: Int] = [:]
            var validationFailures: Set<String> = []
            var warnings = preflight.warnings
            for source in sources {
                do {
                    let bounded = try registry.globallyBoundedRecentSnapshotsImportingAdmittedLegacy(
                        sources: [source],
                        admissions: admissions.filter {
                            $0.source.provider == source.provider
                        },
                        maximumRecords: maximumRecordsPerProvider,
                        maximumGraphNodes: max(0, maximumLegacyGraphNodes),
                        projectRecord: projectRecord,
                        validateActiveSlot: validateActiveSlot
                    )[source.provider] ?? CmuxAgentSessionRegistry.BoundedRecentSnapshot(
                        snapshot: .init(records: [], activeSlots: []),
                        totalRecordCount: 0
                    )
                    recovered[source.provider] = bounded.snapshot
                    totalRecordCounts[source.provider] = bounded.totalRecordCount
                } catch let error as CmuxAgentSessionRegistry.HookInspectionGraphUnionLimitError {
                    throw inspectionGraphLoadFailure(error, registryPath: registryURL.path)
                } catch let error as CmuxAgentSessionRegistry.HookGraphNodeInspectionLimitError {
                    throw inspectionGraphLoadFailure(error, registryPath: registryURL.path)
                } catch let error as CmuxAgentSessionRegistry.HookGraphNodeMalformedRecordError {
                    throw inspectionGraphLoadFailure(error, registryPath: registryURL.path)
                } catch let error as CmuxAgentSessionRegistry.HookInspectionStorageLimitError {
                    throw inspectionStorageLoadFailure(error, registryPath: registryURL.path)
                } catch let failure as CmuxAgentSessionRegistry.HookListProjectionValidationError
                    where failure.provider == source.provider {
                    recovered[source.provider] = .init(records: [], activeSlots: [])
                    totalRecordCounts[source.provider] = 0
                    validationFailures.insert(source.provider)
                } catch let failure as CmuxAgentSessionRegistry.HookLegacySourceImportError
                    where failure.provider == source.provider {
                    do {
                        let fallback = try registry
                            .globallyBoundedRecentSnapshotsImportingAdmittedLegacy(
                                sources: [source],
                                admissions: [],
                                maximumRecords: maximumRecordsPerProvider,
                                maximumGraphNodes: max(0, maximumLegacyGraphNodes),
                                projectRecord: projectRecord,
                                validateActiveSlot: validateActiveSlot
                            )[source.provider] ?? CmuxAgentSessionRegistry.BoundedRecentSnapshot(
                                snapshot: .init(records: [], activeSlots: []),
                                totalRecordCount: 0
                            )
                        guard fallback.totalRecordCount > 0 else {
                            throw AgentHookSessionStoreLoadFailure(
                                provider: source.provider,
                                path: source.url.path,
                                code: .legacySourceImportFailed
                            )
                        }
                        let bridge = AgentHookSessionRegistryBridge(
                            provider: source.provider,
                            statePath: source.url.path,
                            environment: environment,
                            fileManager: fileManager
                        )
                        let validation: AgentHookSessionStoreLoadResult
                        do {
                            validation = try bridge.loadBoundedForInspection(
                                snapshot: fallback.snapshot
                            )
                        } catch is AgentHookSessionStoreLoadFailure {
                            throw AgentHookSessionStoreLoadFailure(
                                provider: source.provider,
                                path: source.url.path,
                                code: .legacySourceImportFailed
                            )
                        }
                        guard validation.warning == nil,
                              !validation.store.sessions.isEmpty else {
                            throw AgentHookSessionStoreLoadFailure(
                                provider: source.provider,
                                path: source.url.path,
                                code: .legacySourceImportFailed
                            )
                        }
                        recovered[source.provider] = fallback.snapshot
                        totalRecordCounts[source.provider] = fallback.totalRecordCount
                        warnings.append(AgentHookSessionStoreLoadWarning(
                            provider: source.provider,
                            path: source.url.path,
                            code: .legacySourceImportFailed,
                            fallback: .registry
                        ))
                    } catch let failure as CmuxAgentSessionRegistry.HookListProjectionValidationError
                        where failure.provider == source.provider {
                        throw AgentHookSessionStoreLoadFailure(
                            provider: source.provider,
                            path: source.url.path,
                            code: .legacySourceImportFailed
                        )
                    } catch let failure as AgentHookSessionStoreLoadFailure {
                        throw failure
                    }
                }
            }
            let validSources = sources.filter {
                !validationFailures.contains($0.provider)
            }
            let consistent: [String: CmuxAgentSessionRegistry.BoundedRecentSnapshot]
            do {
                consistent = try registry.globallyBoundedRecentSnapshotsImportingAdmittedLegacy(
                    sources: validSources,
                    admissions: [],
                    maximumRecords: maximumRecordsPerProvider,
                    maximumGraphNodes: max(0, maximumLegacyGraphNodes),
                    projectRecord: projectRecord,
                    validateActiveSlot: validateActiveSlot
                )
            } catch let error as CmuxAgentSessionRegistry.HookInspectionGraphUnionLimitError {
                throw inspectionGraphLoadFailure(error, registryPath: registryURL.path)
            } catch let error as CmuxAgentSessionRegistry.HookGraphNodeInspectionLimitError {
                throw inspectionGraphLoadFailure(error, registryPath: registryURL.path)
            } catch let error as CmuxAgentSessionRegistry.HookGraphNodeMalformedRecordError {
                throw inspectionGraphLoadFailure(error, registryPath: registryURL.path)
            } catch let error as CmuxAgentSessionRegistry.HookInspectionStorageLimitError {
                throw inspectionStorageLoadFailure(error, registryPath: registryURL.path)
            }
            recovered = consistent.mapValues(\.snapshot)
            totalRecordCounts = consistent.mapValues(\.totalRecordCount)
            for provider in validationFailures {
                recovered[provider] = .init(records: [], activeSlots: [])
                totalRecordCounts[provider] = 0
            }
            return AgentHookSessionRegistrySnapshots(
                snapshots: recovered,
                warnings: warnings,
                totalRecordCounts: totalRecordCounts,
                boundedValidationFailures: validationFailures
            )
        }
    }

    func load(decoder: JSONDecoder = JSONDecoder()) -> ClaudeHookSessionStoreFile {
        if legacyFileSizeExceedsLimit() {
            if let snapshot = try? registry.snapshot(provider: provider),
               let state = try? decode(snapshot, decoder: decoder) {
                return state
            }
            return ClaudeHookSessionStoreFile()
        }
        do {
            let snapshot = try registry.snapshotImportingLegacy(
                provider: provider,
                legacyURL: URL(fileURLWithPath: statePath),
                fileManager: fileManager
            )
            return try decode(snapshot, decoder: decoder)
        } catch {
            // Hook reads must remain available when the bounded SQLite busy
            // timeout expires. A corrupt compatibility projection keeps the
            // last complete SQLite snapshot visible. Writers still fail closed.
            if let snapshot = try? registry.snapshot(provider: provider),
               let state = try? decode(snapshot, decoder: decoder) {
                return state
            }
            return readLegacy(decoder: decoder)
        }
    }

    func lookup(
        sessionID: String,
        decoder: JSONDecoder = JSONDecoder()
    ) throws -> ClaudeHookSessionRecord? {
        try refreshLegacySource()
        guard let stored = try registry.hookRecord(provider: provider, sessionID: sessionID) else {
            return nil
        }
        let record = try decoder.decode(ClaudeHookSessionRecord.self, from: stored.json)
        guard record.sessionId == stored.sessionID else {
            throw ProjectionError.recordIdentityMismatch
        }
        return record
    }

    func activeContext(
        workspaceID: String,
        surfaceID: String?,
        decoder: JSONDecoder = JSONDecoder()
    ) throws -> ClaudeHookSessionStoreFile {
        try refreshLegacySource()
        return try decode(
            registry.hookActiveContext(
                provider: provider,
                workspaceID: workspaceID,
                surfaceID: surfaceID
            ).snapshot,
            decoder: decoder
        )
    }

    func fallbackRecords(
        workspaceID: String?,
        surfaceID: String?,
        decoder: JSONDecoder = JSONDecoder()
    ) throws -> [ClaudeHookSessionRecord] {
        try refreshLegacySource()
        return try registry.hookFallbackRecords(
            provider: provider,
            workspaceID: workspaceID,
            surfaceID: surfaceID
        ).map { stored in
            let record = try decoder.decode(ClaudeHookSessionRecord.self, from: stored.json)
            guard record.sessionId == stored.sessionID else {
                throw ProjectionError.recordIdentityMismatch
            }
            return record
        }
    }

    func runningRecords(
        workspaceID: String,
        surfaceID: String?,
        decoder: JSONDecoder = JSONDecoder()
    ) throws -> [ClaudeHookSessionRecord] {
        try refreshLegacySource()
        return try registry.hookRunningRecords(
            provider: provider,
            workspaceID: workspaceID,
            surfaceID: surfaceID
        ).map { stored in
            let record = try decoder.decode(ClaudeHookSessionRecord.self, from: stored.json)
            guard record.sessionId == stored.sessionID else {
                throw ProjectionError.recordIdentityMismatch
            }
            return record
        }
    }

    func load(
        snapshot: CmuxAgentSessionRegistry.Snapshot,
        decoder: JSONDecoder = JSONDecoder()
    ) -> ClaudeHookSessionStoreFile {
        (try? loadForInspection(snapshot: snapshot, decoder: decoder).store)
            ?? ClaudeHookSessionStoreFile()
    }

    func loadForInspection(
        snapshot: CmuxAgentSessionRegistry.Snapshot,
        decoder: JSONDecoder = JSONDecoder()
    ) throws -> AgentHookSessionStoreLoadResult {
        do {
            let store = try decode(snapshot, decoder: decoder)
            guard inspectionProjectionIdentityIsConsistent(store) else {
                throw ProjectionError.slotIdentityMismatch
            }
            return AgentHookSessionStoreLoadResult(
                store: store,
                warning: nil
            )
        } catch {
            guard let legacy = readLegacyIfPresent(
                decoder: decoder,
                requireInspectionProjectionIdentity: true
            ) else {
                throw AgentHookSessionStoreLoadFailure(
                    provider: provider,
                    path: registryURL.path,
                    code: .authoritativeSnapshotDecodeFailed
                )
            }
            return AgentHookSessionStoreLoadResult(
                store: legacy,
                warning: AgentHookSessionStoreLoadWarning(
                    provider: provider,
                    path: registryURL.path,
                    code: .authoritativeSnapshotDecodeFailed,
                    fallback: .legacy
                )
            )
        }
    }

    func loadBoundedForInspection(
        snapshot: CmuxAgentSessionRegistry.Snapshot,
        authoritativeValidationFailed: Bool = false,
        decoder: JSONDecoder = JSONDecoder()
    ) throws -> AgentHookSessionStoreLoadResult {
        do {
            guard !authoritativeValidationFailed else {
                throw ProjectionError.recordIdentityMismatch
            }
            let store = try decode(snapshot, decoder: decoder)
            guard inspectionProjectionIdentityIsConsistent(store) else {
                throw ProjectionError.slotIdentityMismatch
            }
            return AgentHookSessionStoreLoadResult(store: store, warning: nil)
        } catch {
            guard let legacy = readLegacyIfPresent(
                decoder: decoder,
                requireInspectionProjectionIdentity: true
            ) else {
                throw AgentHookSessionStoreLoadFailure(
                    provider: provider,
                    path: registryURL.path,
                    code: .authoritativeSnapshotDecodeFailed
                )
            }
            return AgentHookSessionStoreLoadResult(
                store: legacy,
                warning: AgentHookSessionStoreLoadWarning(
                    provider: provider,
                    path: registryURL.path,
                    code: .authoritativeSnapshotDecodeFailed,
                    fallback: .legacy
                )
            )
        }
    }

    func mutate<T>(
        _ body: (inout ClaudeHookSessionStoreFile) throws -> T
    ) throws -> (result: T, state: ClaudeHookSessionStoreFile) {
        _ = try registry.snapshotImportingLegacy(
            provider: provider,
            legacyURL: URL(fileURLWithPath: statePath),
            fileManager: fileManager
        )
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        return try registry.mutateSnapshot(provider: provider) { snapshot in
            var state = try decode(snapshot, decoder: decoder)
            let previous = state
            let result = try body(&state)

            var recordsByID = Dictionary(uniqueKeysWithValues: snapshot.records.map { ($0.sessionID, $0) })
            for (sessionID, record) in state.sessions {
                guard previous.sessions[sessionID]?.updatedAt != record.updatedAt
                        || previous.sessions[sessionID] == nil else { continue }
                if let existing = recordsByID[sessionID],
                   existing.writerGeneration > CmuxAgentSessionRegistry.currentWriterGeneration {
                    throw MutationError.newerWriterGeneration
                }
                recordsByID[sessionID] = CmuxAgentSessionRegistry.Record(
                    provider: provider,
                    sessionID: sessionID,
                    updatedAt: record.updatedAt,
                    json: try encoder.encode(record)
                )
            }
            for sessionID in Set(previous.sessions.keys).subtracting(state.sessions.keys) {
                guard recordsByID[sessionID]?.writerGeneration ?? 0
                        <= CmuxAgentSessionRegistry.currentWriterGeneration else {
                    throw MutationError.newerWriterGeneration
                }
                recordsByID.removeValue(forKey: sessionID)
            }
            snapshot.records = Array(recordsByID.values)

            let previousSlots = slotMap(previous)
            let currentSlots = slotMap(state)
            var slotsByKey = Dictionary(uniqueKeysWithValues: snapshot.activeSlots.map {
                (CmuxAgentSessionRegistry.slotKey(scope: $0.scope, scopeID: $0.scopeID), $0)
            })
            for (key, slot) in currentSlots {
                let old = previousSlots[key]
                guard old?.record.updatedAt != slot.record.updatedAt
                        || old?.record.sessionId != slot.record.sessionId
                        || old?.record.turnId != slot.record.turnId else { continue }
                if let existing = slotsByKey[key],
                   existing.writerGeneration > CmuxAgentSessionRegistry.currentWriterGeneration {
                    throw MutationError.newerWriterGeneration
                }
                slotsByKey[key] = CmuxAgentSessionRegistry.ActiveSlot(
                    provider: provider,
                    scope: slot.scope,
                    scopeID: slot.scopeID,
                    sessionID: slot.record.sessionId,
                    updatedAt: slot.record.updatedAt,
                    json: try encoder.encode(slot.record)
                )
            }
            for key in Set(previousSlots.keys).subtracting(currentSlots.keys) {
                guard slotsByKey[key]?.writerGeneration ?? 0
                        <= CmuxAgentSessionRegistry.currentWriterGeneration else {
                    throw MutationError.newerWriterGeneration
                }
                slotsByKey.removeValue(forKey: key)
            }
            snapshot.activeSlots = Array(slotsByKey.values)
            return (result, state)
        }
    }

    func mutateSession<T>(
        sessionID: String,
        workspaceID: String?,
        surfaceID: String?,
        includeOwnedSlots: Bool = true,
        _ body: (inout ClaudeHookSessionStoreFile) throws -> T
    ) throws -> (
        result: T,
        state: ClaudeHookSessionStoreFile,
        revision: Int64,
        recordsRead: Int,
        slotsRead: Int,
        recordsWritten: Int,
        slotsWritten: Int
    ) {
        try refreshLegacySource()
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        var explicitSlots = Set<CmuxAgentSessionRegistry.ActiveSlotKey>()
        if let workspaceID = normalized(workspaceID) {
            explicitSlots.insert(.init(scope: .workspace, scopeID: workspaceID))
        }
        if let surfaceID = normalized(surfaceID) {
            explicitSlots.insert(.init(scope: .surface, scopeID: surfaceID))
        }
        let mutation = try registry.mutateHookSession(
            provider: provider,
            sessionID: sessionID,
            activeSlots: explicitSlots,
            includeOwnedSlots: includeOwnedSlots
        ) { snapshot in
            var state = try decode(snapshot, decoder: decoder)
            let previous = state
            let result = try body(&state)

            let previousRecord = snapshot.records.first { $0.sessionID == sessionID }
            let previousValue = previous.sessions[sessionID]
            let currentValue = state.sessions[sessionID]
            if let currentValue {
                let currentTypedJSON = try encoder.encode(currentValue)
                let previousTypedJSON = try previousValue.map(encoder.encode)
                if previousTypedJSON != currentTypedJSON || previousRecord == nil {
                    if let previousRecord,
                       previousRecord.writerGeneration > CmuxAgentSessionRegistry.currentWriterGeneration {
                        throw MutationError.newerWriterGeneration
                    }
                    snapshot.records = [CmuxAgentSessionRegistry.Record(
                        provider: provider,
                        sessionID: sessionID,
                        updatedAt: currentValue.updatedAt,
                        json: try mergedJSON(
                            original: previousRecord?.json,
                            previousTyped: previousTypedJSON,
                            currentTyped: currentTypedJSON
                        )
                    )]
                }
            } else {
                if let previousRecord,
                   previousRecord.writerGeneration > CmuxAgentSessionRegistry.currentWriterGeneration {
                    throw MutationError.newerWriterGeneration
                }
                snapshot.records = []
            }

            let previousSlots = slotMap(previous)
            let currentSlots = slotMap(state)
            let storedSlots = Dictionary(uniqueKeysWithValues: snapshot.activeSlots.map {
                (CmuxAgentSessionRegistry.slotKey(scope: $0.scope, scopeID: $0.scopeID), $0)
            })
            var projectedSlots: [CmuxAgentSessionRegistry.ActiveSlot] = []
            projectedSlots.reserveCapacity(currentSlots.count)
            for (key, slot) in currentSlots {
                let oldValue = previousSlots[key]?.record
                let oldTypedJSON = try oldValue.map(encoder.encode)
                let currentTypedJSON = try encoder.encode(slot.record)
                if oldTypedJSON == currentTypedJSON, let stored = storedSlots[key] {
                    projectedSlots.append(stored)
                    continue
                }
                if let stored = storedSlots[key],
                   stored.writerGeneration > CmuxAgentSessionRegistry.currentWriterGeneration,
                   oldTypedJSON != currentTypedJSON {
                    throw MutationError.newerWriterGeneration
                }
                projectedSlots.append(CmuxAgentSessionRegistry.ActiveSlot(
                    provider: provider,
                    scope: slot.scope,
                    scopeID: slot.scopeID,
                    sessionID: slot.record.sessionId,
                    updatedAt: slot.record.updatedAt,
                    writerGeneration: max(
                        storedSlots[key]?.writerGeneration ?? 0,
                        CmuxAgentSessionRegistry.currentWriterGeneration
                    ),
                    json: try mergedJSON(
                        original: storedSlots[key]?.json,
                        previousTyped: oldTypedJSON,
                        currentTyped: currentTypedJSON
                    )
                ))
            }
            for (key, stored) in storedSlots where currentSlots[key] == nil {
                guard stored.writerGeneration <= CmuxAgentSessionRegistry.currentWriterGeneration else {
                    throw MutationError.newerWriterGeneration
                }
            }
            snapshot.activeSlots = projectedSlots
            return (result, state)
        }
        try projectLegacy(including: mutation.revision)
        return (
            mutation.result.0,
            mutation.result.1,
            mutation.revision,
            mutation.recordsRead,
            mutation.slotsRead,
            mutation.recordsWritten,
            mutation.slotsWritten
        )
    }

    func projectLegacy(including requiredRevision: Int64) throws {
        try registry.projectHookLegacyStore(
            provider: provider,
            to: URL(fileURLWithPath: statePath),
            including: requiredRevision,
            fileManager: fileManager
        )
    }

    func markLegacySourceCurrent() {
        guard let stamp = CmuxAgentSessionRegistry.LegacyStamp.read(path: statePath, fileManager: fileManager) else {
            return
        }
        try? registry.markLegacySource(provider: provider, stamp: stamp)
    }

    private func readLegacy(decoder: JSONDecoder) -> ClaudeHookSessionStoreFile {
        readLegacyIfPresent(decoder: decoder) ?? ClaudeHookSessionStoreFile()
    }

    private func refreshLegacySource() throws {
        try validateLegacyFileSize()
        let result = try registry.refreshLegacySources(
            [CmuxAgentSessionRegistry.LegacySource(
                provider: provider,
                url: URL(fileURLWithPath: statePath)
            )],
            fileManager: fileManager
        )
        guard !result.failedProviders.contains(provider)
                || !fileManager.fileExists(atPath: statePath) else {
            throw AgentHookSessionStoreLoadFailure(
                provider: provider,
                path: statePath,
                code: .legacySourceImportFailed
            )
        }
    }

    private func mergedJSON(
        original: Data?,
        previousTyped: Data?,
        currentTyped: Data
    ) throws -> Data {
        var object = original.flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        } ?? [:]
        let previous = previousTyped.flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        } ?? [:]
        guard let current = try JSONSerialization.jsonObject(with: currentTyped) as? [String: Any] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        for key in Set(previous.keys).union(current.keys) {
            object.removeValue(forKey: key)
        }
        object.merge(current) { _, new in new }
        guard JSONSerialization.isValidJSONObject(object) else {
            throw CocoaError(.propertyListWriteInvalid)
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func readLegacyIfPresent(
        decoder: JSONDecoder,
        requireInspectionProjectionIdentity: Bool = false
    ) -> ClaudeHookSessionStoreFile? {
        guard !legacyFileSizeExceedsLimit(),
              fileManager.fileExists(atPath: statePath),
              let data = readLegacyDataIfWithinLimit(),
              let store = try? decoder.decode(ClaudeHookSessionStoreFile.self, from: data),
              !requireInspectionProjectionIdentity || inspectionProjectionIdentityIsConsistent(store) else {
            return nil
        }
        return store
    }

    static func preflightInspectionSources(
        _ sources: [CmuxAgentSessionRegistry.LegacySource],
        registry: CmuxAgentSessionRegistry,
        registryPath: String,
        fileManager: FileManager,
        maximumLegacyGraphNodes: Int,
        limits: InspectionStorageLimits = .production,
        admissionLoader: InspectionAdmissionLoader? = nil
    ) throws -> InspectionPreflightResult {
        var preflights: [InspectionSourcePreflight] = []
        var admissions: [CmuxAgentSessionRegistry.HookLegacySourceAdmission] = []
        var warnings: [AgentHookSessionStoreLoadWarning] = []
        var selectedLegacyGraphNodes = 0
        let loadAdmission: InspectionAdmissionLoader = admissionLoader ?? {
            source, stamp, remainingGraphNodes in
            try registry.hookLegacySourceAdmission(
                source: source,
                expectedStamp: stamp,
                fileManager: fileManager,
                maximumBytes: max(0, limits.legacyFileBytes),
                maximumSessions: maximumLegacySessions,
                maximumGraphNodes: remainingGraphNodes,
                maximumRecordBytes: max(0, limits.recordBytes)
            )
        }
        let storageMetricsByProvider = try registry.hookStorageMetrics(
            providers: sources.map(\.provider)
        )
        for source in sources {
            guard let storageMetrics = storageMetricsByProvider[source.provider] else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let initialStamp = CmuxAgentSessionRegistry.LegacyStamp.read(
                path: source.url.path,
                fileManager: fileManager
            )
            let sourceChanged = if let initialStamp {
                try !registry.legacySourceIsCurrent(
                    provider: source.provider,
                    stamp: initialStamp
                )
            } else {
                false
            }
            let changedLegacyBytes = sourceChanged ? max(0, initialStamp?.size ?? 0) : 0
            preflights.append(InspectionSourcePreflight(
                provider: source.provider,
                registryPath: registryPath,
                legacyPath: source.url.path,
                metrics: storageMetrics,
                legacyBytes: changedLegacyBytes
            ))
            // The aggregate cap applies to retained source bytes. Check it
            // incrementally before reading this compatibility revision so a
            // set of individually valid files cannot allocate past the cap.
            try validateInspectionStorage(preflights, limits: limits)

            guard sourceChanged, var expectedStamp = initialStamp else { continue }
            var admissionAttempts = 0
            admissionLoop: while admissionAttempts < 2 {
                if try registry.legacySourceIsCurrent(
                    provider: source.provider,
                    stamp: expectedStamp
                ) {
                    preflights[preflights.index(before: preflights.endIndex)].legacyBytes = 0
                    break admissionLoop
                }
                preflights[preflights.index(before: preflights.endIndex)].legacyBytes =
                    max(0, expectedStamp.size)
                try validateInspectionStorage(preflights, limits: limits)
                do {
                    let admission = try loadAdmission(
                        source,
                        expectedStamp,
                        max(0, maximumLegacyGraphNodes - selectedLegacyGraphNodes)
                    )
                    admissions.append(admission)
                    preflights[preflights.index(before: preflights.endIndex)].legacyMetrics =
                        admission.metrics
                    selectedLegacyGraphNodes += admission.metrics.graphNodeCount
                    break admissionLoop
                } catch {
                    let latestStamp = CmuxAgentSessionRegistry.LegacyStamp.read(
                        path: source.url.path,
                        fileManager: fileManager
                    )
                    let pathRevisionChanged = if let latestStamp {
                        latestStamp != expectedStamp
                    } else {
                        true
                    }
                    if error is CmuxAgentSessionRegistry.HookLegacySourceRevisionChangedError
                        || pathRevisionChanged {
                        admissionAttempts += 1
                        if admissionAttempts < 2, let latestStamp {
                            expectedStamp = latestStamp
                            continue admissionLoop
                        }
                        guard canonicalInspectionFallbackIsValid(
                            registry: registry,
                            provider: source.provider,
                            limits: limits
                        ) else {
                            throw AgentHookSessionStoreLoadFailure(
                                provider: source.provider,
                                path: source.url.path,
                                code: .legacySourceImportFailed
                            )
                        }
                        preflights[preflights.index(before: preflights.endIndex)].legacyBytes = 0
                        warnings.append(AgentHookSessionStoreLoadWarning(
                            provider: source.provider,
                            path: source.url.path,
                            code: .legacySourceImportFailed,
                            fallback: .registry
                        ))
                        break admissionLoop
                    }
                    if let error = error as? CmuxAgentSessionRegistry.HookLegacySourceInspectionLimitError {
                        throw legacyInspectionFailure(
                            provider: source.provider,
                            error: error,
                            aggregateMaximumGraphNodes: maximumLegacyGraphNodes,
                            registryPath: registryPath
                        )
                    }
                    if let error = error as? CmuxAgentSessionRegistry.HookLegacySourceSizeError {
                        throw AgentHookSessionStoreLoadFailure(
                            provider: source.provider,
                            path: source.url.path,
                            code: .storageLimitExceeded,
                            scope: .legacyFile,
                            observedBytes: error.observedBytes,
                            maximumBytes: error.maximumBytes,
                            canonicalPath: registryPath
                        )
                    }
                    throw AgentHookSessionStoreLoadFailure(
                        provider: source.provider,
                        path: source.url.path,
                        code: .legacySourceImportFailed
                    )
                }
            }
        }
        try validateInspectionStorage(preflights, limits: limits)
        return InspectionPreflightResult(admissions: admissions, warnings: warnings)
    }

    private static func canonicalInspectionFallbackIsValid(
        registry: CmuxAgentSessionRegistry,
        provider: String,
        limits: InspectionStorageLimits
    ) -> Bool {
        guard let snapshot = try? registry.hookBoundedSnapshot(
            provider: provider,
            maximumRecords: maximumLegacySessions,
            maximumProviderBytes: max(0, limits.providerBytes),
            maximumRecordBytes: max(0, limits.recordBytes)
        ), !snapshot.records.isEmpty else {
            return false
        }
        let decoder = JSONDecoder()
        do {
            var recordsByID: [String: ClaudeHookSessionRecord] = [:]
            recordsByID.reserveCapacity(snapshot.records.count)
            for stored in snapshot.records {
                let record = try decoder.decode(ClaudeHookSessionRecord.self, from: stored.json)
                guard record.sessionId == stored.sessionID else { return false }
                recordsByID[stored.sessionID] = record
            }
            for stored in snapshot.activeSlots {
                let slot = try decoder.decode(ClaudeHookActiveSessionRecord.self, from: stored.json)
                guard slot.sessionId == stored.sessionID else { return false }
                let owner = recordsByID[stored.sessionID]
                switch stored.scope {
                case .workspace:
                    guard owner?.workspaceId == stored.scopeID else { return false }
                case .surface:
                    guard owner?.surfaceId == stored.scopeID else { return false }
                }
            }
            return true
        } catch {
            return false
        }
    }

    private static func inspectionGraphLoadFailure(
        _ error: CmuxAgentSessionRegistry.HookInspectionGraphUnionLimitError,
        registryPath: String
    ) -> AgentHookSessionStoreLoadFailure {
        AgentHookSessionStoreLoadFailure(
            provider: error.provider,
            path: error.path,
            code: .storageLimitExceeded,
            scope: .legacyGraphNodes,
            observedCount: error.observed,
            maximumCount: error.maximum,
            canonicalPath: registryPath
        )
    }

    private static func inspectionGraphLoadFailure(
        _ error: CmuxAgentSessionRegistry.HookGraphNodeInspectionLimitError,
        registryPath: String
    ) -> AgentHookSessionStoreLoadFailure {
        AgentHookSessionStoreLoadFailure(
            provider: error.provider,
            path: registryPath,
            code: .storageLimitExceeded,
            scope: .registryGraphNodes,
            observedCount: error.observed,
            maximumCount: error.maximum,
            canonicalPath: registryPath
        )
    }

    private static func inspectionGraphLoadFailure(
        _ error: CmuxAgentSessionRegistry.HookGraphNodeMalformedRecordError,
        registryPath: String
    ) -> AgentHookSessionStoreLoadFailure {
        AgentHookSessionStoreLoadFailure(
            provider: error.provider,
            path: registryPath,
            code: .authoritativeSnapshotDecodeFailed,
            scope: .registryRecord,
            sessionID: error.sessionID,
            canonicalPath: registryPath
        )
    }

    private static func inspectionStorageLoadFailure(
        _ error: CmuxAgentSessionRegistry.HookInspectionStorageLimitError,
        registryPath: String
    ) -> AgentHookSessionStoreLoadFailure {
        let scope: AgentHookSessionStoreLoadFailure.Scope = switch error.scope {
        case .record: .registryRecord
        case .provider: .registryProvider
        case .selection: .selectionMaterialization
        }
        return AgentHookSessionStoreLoadFailure(
            provider: error.provider,
            path: registryPath,
            code: .storageLimitExceeded,
            scope: scope,
            sessionID: error.sessionID,
            observedBytes: error.observed,
            maximumBytes: error.maximum,
            canonicalPath: registryPath
        )
    }

    private static func legacyInspectionFailure(
        provider: String,
        error: CmuxAgentSessionRegistry.HookLegacySourceInspectionLimitError,
        aggregateMaximumGraphNodes: Int,
        registryPath: String
    ) -> AgentHookSessionStoreLoadFailure {
        switch error.scope {
        case .sessions:
            AgentHookSessionStoreLoadFailure(
                provider: provider,
                path: error.path,
                code: .storageLimitExceeded,
                scope: .legacySessions,
                observedCount: error.observed,
                maximumCount: error.maximum,
                canonicalPath: registryPath
            )
        case .graphNodes:
            AgentHookSessionStoreLoadFailure(
                provider: provider,
                path: error.path,
                code: .storageLimitExceeded,
                scope: .legacyGraphNodes,
                sessionID: error.sessionID,
                observedCount: Int64(aggregateMaximumGraphNodes) + 1,
                maximumCount: Int64(aggregateMaximumGraphNodes),
                canonicalPath: registryPath
            )
        case .recordBytes, .identifierBytes:
            AgentHookSessionStoreLoadFailure(
                provider: provider,
                path: error.path,
                code: .storageLimitExceeded,
                scope: .legacyRecord,
                sessionID: error.sessionID,
                observedBytes: error.observed,
                maximumBytes: error.maximum,
                canonicalPath: registryPath
            )
        }
    }

    static func validateInspectionStorage(
        _ sources: [InspectionSourcePreflight],
        limits: InspectionStorageLimits = .production
    ) throws {
        let recordBytesLimit = max(0, limits.recordBytes)
        let providerBytesLimit = max(0, limits.providerBytes)
        let selectionBytesLimit = max(0, limits.selectionBytes)
        let legacyFileBytesLimit = max(0, limits.legacyFileBytes)
        var selectedBytes: Int64 = 0
        for source in sources {
            let metrics = source.metrics
            if metrics.largestRecordBytes > recordBytesLimit {
                throw AgentHookSessionStoreLoadFailure(
                    provider: source.provider,
                    path: source.registryPath,
                    code: .storageLimitExceeded,
                    scope: .registryRecord,
                    sessionID: metrics.largestRecordSessionID,
                    observedBytes: metrics.largestRecordBytes,
                    maximumBytes: recordBytesLimit
                )
            }
            if metrics.totalBytes > providerBytesLimit {
                throw AgentHookSessionStoreLoadFailure(
                    provider: source.provider,
                    path: source.registryPath,
                    code: .storageLimitExceeded,
                    scope: .registryProvider,
                    observedBytes: metrics.totalBytes,
                    maximumBytes: providerBytesLimit
                )
            }
            if source.legacyBytes > legacyFileBytesLimit {
                throw AgentHookSessionStoreLoadFailure(
                    provider: source.provider,
                    path: source.legacyPath,
                    code: .storageLimitExceeded,
                    scope: .legacyFile,
                    observedBytes: source.legacyBytes,
                    maximumBytes: legacyFileBytesLimit,
                    canonicalPath: source.registryPath
                )
            }
            let (providerBytes, providerOverflow) = metrics.totalBytes.addingReportingOverflow(
                source.legacyBytes
            )
            let boundedProviderBytes: Int64 = providerOverflow ? .max : providerBytes
            if boundedProviderBytes > providerBytesLimit {
                throw AgentHookSessionStoreLoadFailure(
                    provider: source.provider,
                    path: source.legacyBytes > 0 ? source.legacyPath : source.registryPath,
                    code: .storageLimitExceeded,
                    scope: .providerMaterialization,
                    observedBytes: boundedProviderBytes,
                    maximumBytes: providerBytesLimit
                )
            }
            let (sum, overflow) = selectedBytes.addingReportingOverflow(boundedProviderBytes)
            selectedBytes = overflow ? .max : sum
            if selectedBytes > selectionBytesLimit {
                throw AgentHookSessionStoreLoadFailure(
                    provider: source.provider,
                    path: source.registryPath,
                    code: .storageLimitExceeded,
                    scope: .selectionMaterialization,
                    observedBytes: selectedBytes,
                    maximumBytes: selectionBytesLimit
                )
            }
        }
    }

    private func validateLegacyFileSize() throws {
        guard let stamp = CmuxAgentSessionRegistry.LegacyStamp.read(
            path: statePath,
            fileManager: fileManager
        ), stamp.size > Self.maximumLegacyFileBytes else {
            return
        }
        throw AgentHookSessionStoreLoadFailure(
            provider: provider,
            path: statePath,
            code: .storageLimitExceeded,
            scope: .legacyFile,
            observedBytes: stamp.size,
            maximumBytes: Self.maximumLegacyFileBytes
        )
    }

    private func legacyFileSizeExceedsLimit() -> Bool {
        guard let stamp = CmuxAgentSessionRegistry.LegacyStamp.read(
            path: statePath,
            fileManager: fileManager
        ) else {
            return false
        }
        return stamp.size > Self.maximumLegacyFileBytes
    }

    private func readLegacyDataIfWithinLimit() -> Data? {
        try? registry.readHookLegacySourceData(
            at: URL(fileURLWithPath: statePath),
            maximumBytes: Self.maximumLegacyFileBytes
        )
    }

    private func inspectionProjectionIdentityIsConsistent(
        _ store: ClaudeHookSessionStoreFile
    ) -> Bool {
        guard store.sessions.allSatisfy({ sessionID, record in
            sessionID == record.sessionId
        }) else { return false }
        guard store.activeSessionsByWorkspace.allSatisfy({ workspaceID, slot in
            store.sessions[slot.sessionId]?.workspaceId == workspaceID
        }) else { return false }
        return store.activeSessionsBySurface.allSatisfy({ surfaceID, slot in
            store.sessions[slot.sessionId]?.surfaceId == surfaceID
        })
    }

    private func decode(
        _ snapshot: CmuxAgentSessionRegistry.Snapshot,
        decoder: JSONDecoder
    ) throws -> ClaudeHookSessionStoreFile {
        var state = ClaudeHookSessionStoreFile()
        for stored in snapshot.records {
            let record = try decoder.decode(ClaudeHookSessionRecord.self, from: stored.json)
            guard record.sessionId == stored.sessionID else {
                throw ProjectionError.recordIdentityMismatch
            }
            state.sessions[stored.sessionID] = record
        }
        for slot in snapshot.activeSlots {
            let record = try decoder.decode(ClaudeHookActiveSessionRecord.self, from: slot.json)
            guard record.sessionId == slot.sessionID else {
                throw ProjectionError.slotIdentityMismatch
            }
            switch slot.scope {
            case .workspace: state.activeSessionsByWorkspace[slot.scopeID] = record
            case .surface: state.activeSessionsBySurface[slot.scopeID] = record
            }
        }
        return state
    }

    private enum ProjectionError: Error {
        case recordIdentityMismatch
        case slotIdentityMismatch
    }

    private struct SlotValue {
        var scope: CmuxAgentSessionRegistry.Scope
        var scopeID: String
        var record: ClaudeHookActiveSessionRecord
    }

    private func slotMap(_ state: ClaudeHookSessionStoreFile) -> [String: SlotValue] {
        var result: [String: SlotValue] = [:]
        for (scopeID, record) in state.activeSessionsByWorkspace {
            let scope = CmuxAgentSessionRegistry.Scope.workspace
            result[CmuxAgentSessionRegistry.slotKey(scope: scope, scopeID: scopeID)] = SlotValue(
                scope: scope,
                scopeID: scopeID,
                record: record
            )
        }
        for (scopeID, record) in state.activeSessionsBySurface {
            let scope = CmuxAgentSessionRegistry.Scope.surface
            result[CmuxAgentSessionRegistry.slotKey(scope: scope, scopeID: scopeID)] = SlotValue(
                scope: scope,
                scopeID: scopeID,
                record: record
            )
        }
        return result
    }

    private func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}
