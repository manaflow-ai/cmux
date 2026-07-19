import Foundation
import SQLite3

extension CmuxAgentSessionRegistry {
    public struct HookInspectionStorageLimitError: Error, Equatable, Sendable {
        public enum Scope: String, Equatable, Sendable {
            case record
            case provider
            case selection
        }

        public var scope: Scope
        public var provider: String
        public var sessionID: String?
        public var observed: Int64
        public var maximum: Int64

        public init(
            scope: Scope,
            provider: String,
            sessionID: String? = nil,
            observed: Int64,
            maximum: Int64
        ) {
            self.scope = scope
            self.provider = provider
            self.sessionID = sessionID
            self.observed = observed
            self.maximum = maximum
        }
    }

    /// Imports only compatibility bytes that a caller already admitted, then
    /// validates and materializes the selected registry in one SQLite snapshot.
    public func snapshotsImportingAdmittedLegacy(
        sources: [LegacySource],
        admissions: [HookLegacySourceAdmission],
        maximumGraphNodes: Int = 20_000,
        maximumRecordBytes: Int64 = 4 * 1_024 * 1_024,
        maximumProviderBytes: Int64 = 64 * 1_024 * 1_024,
        maximumSelectionBytes: Int64 = 128 * 1_024 * 1_024
    ) throws -> [String: Snapshot] {
        let sources = uniqueInspectionSources(sources)
        let admitted = try validatedInspectionAdmissions(
            sources: sources,
            admissions: admissions
        )
        return try withDatabase { database in
            try ensureHookHotPathSchema(database)
            return try inspectionTransaction(database, needsWrite: !admitted.isEmpty) {
                try importAdmittedLegacy(database: database, admissions: admitted)
                try validateHookInspectionGraph(
                    database: database,
                    providers: sources.map(\.provider),
                    admissions: admitted,
                    maximumGraphNodes: maximumGraphNodes
                )
                try validateAdmittedInspectionStorage(
                    database: database,
                    providers: sources.map(\.provider),
                    maximumRecordBytes: maximumRecordBytes,
                    maximumProviderBytes: maximumProviderBytes,
                    maximumSelectionBytes: maximumSelectionBytes
                )
                return try Dictionary(
                    uniqueKeysWithValues: sources.map { source in
                        (
                            source.provider,
                            Snapshot(
                                records: try readRecords(
                                    database: database, provider: source.provider),
                                activeSlots: try readSlots(
                                    database: database, provider: source.provider)
                            )
                        )
                    })
            }
        }
    }

    /// Bounded-list counterpart to `snapshotsImportingAdmittedLegacy`.
    public func boundedRecentSnapshotsImportingAdmittedLegacy(
        sources: [LegacySource],
        admissions: [HookLegacySourceAdmission],
        maximumRecordsPerProvider: Int,
        maximumGraphNodes: Int = 20_000,
        maximumRecordBytes: Int64 = 4 * 1_024 * 1_024,
        maximumProviderBytes: Int64 = 64 * 1_024 * 1_024,
        maximumSelectionBytes: Int64 = 128 * 1_024 * 1_024,
        validateRecord: ((String, Record) throws -> Void)? = nil,
        validateActiveSlot: ((String, ActiveSlot) throws -> Void)? = nil
    ) throws -> [String: BoundedRecentSnapshot] {
        let sources = uniqueInspectionSources(sources)
        let admitted = try validatedInspectionAdmissions(
            sources: sources,
            admissions: admissions
        )
        let maximumRecordsPerProvider = max(0, maximumRecordsPerProvider)
        return try withDatabase { database in
            try ensureHookHotPathSchema(database)
            return try inspectionTransaction(database, needsWrite: !admitted.isEmpty) {
                try importAdmittedLegacy(database: database, admissions: admitted)
                try validateHookInspectionGraph(
                    database: database,
                    providers: sources.map(\.provider),
                    admissions: admitted,
                    maximumGraphNodes: maximumGraphNodes
                )
                try validateAdmittedInspectionStorage(
                    database: database,
                    providers: sources.map(\.provider),
                    maximumRecordBytes: maximumRecordBytes,
                    maximumProviderBytes: maximumProviderBytes,
                    maximumSelectionBytes: maximumSelectionBytes
                )
                return try Dictionary(
                    uniqueKeysWithValues: sources.map { source in
                        if let validateRecord {
                            try validateListRecordPayloads(
                                database: database,
                                provider: source.provider,
                                validate: { try validateRecord(source.provider, $0) }
                            )
                        }
                        let recent = try readBoundedListRecords(
                            database: database,
                            provider: source.provider,
                            limit: maximumRecordsPerProvider
                        )
                        return (
                            source.provider,
                            BoundedRecentSnapshot(
                                snapshot: Snapshot(
                                    records: recent,
                                    activeSlots: try readListSlots(
                                        database: database,
                                        provider: source.provider,
                                        selectedSessionIDs: Set(recent.map(\.sessionID)),
                                        validate: validateActiveSlot.map { validate in
                                            { try validate(source.provider, $0) }
                                        }
                                    )
                                ),
                                totalRecordCount: try recordCount(
                                    database: database,
                                    provider: source.provider
                                )
                            )
                        )
                    })
            }
        }
    }

    /// Validates every selected provider but materializes only one global top
    /// K. This keeps unfiltered CLI list reads proportional to K after the
    /// mandatory fail-closed validation pass, instead of retaining K rows for
    /// each configured provider.
    public func globallyBoundedRecentSnapshotsImportingAdmittedLegacy(
        sources: [LegacySource],
        admissions: [HookLegacySourceAdmission],
        maximumRecords: Int,
        maximumGraphNodes: Int = 20_000,
        maximumRecordBytes: Int64 = 4 * 1_024 * 1_024,
        maximumProviderBytes: Int64 = 64 * 1_024 * 1_024,
        maximumSelectionBytes: Int64 = 128 * 1_024 * 1_024,
        validateRecord: ((String, Record) throws -> Void)? = nil,
        validateActiveSlot: ((String, ActiveSlot) throws -> Void)? = nil
    ) throws -> [String: BoundedRecentSnapshot] {
        let sources = uniqueInspectionSources(sources)
        let admitted = try validatedInspectionAdmissions(
            sources: sources,
            admissions: admissions
        )
        let maximumRecords = max(0, maximumRecords)
        return try withDatabase { database in
            try ensureHookHotPathSchema(database)
            return try inspectionTransaction(database, needsWrite: !admitted.isEmpty) {
                try importAdmittedLegacy(database: database, admissions: admitted)
                let providers = sources.map(\.provider)
                try validateHookInspectionGraph(
                    database: database,
                    providers: providers,
                    admissions: admitted,
                    maximumGraphNodes: maximumGraphNodes
                )
                try validateAdmittedInspectionStorage(
                    database: database,
                    providers: providers,
                    maximumRecordBytes: maximumRecordBytes,
                    maximumProviderBytes: maximumProviderBytes,
                    maximumSelectionBytes: maximumSelectionBytes
                )
                guard !providers.isEmpty else { return [:] }
                if let validateRecord {
                    try validateGlobalListRecordPayloads(
                        database: database,
                        providers: providers,
                        validate: validateRecord
                    )
                } else {
                    for provider in providers {
                        try validateBoundedListRecords(
                            database: database,
                            provider: provider
                        )
                    }
                }
                let records = try readGloballyBoundedListRecords(
                    database: database,
                    providers: providers,
                    limit: maximumRecords
                )
                let selectedSessionIDs = Dictionary(
                    grouping: records,
                    by: \.provider
                ).mapValues { Set($0.map(\.sessionID)) }
                let slots = try readGlobalListSlots(
                    database: database,
                    providers: providers,
                    selectedSessionIDs: selectedSessionIDs,
                    validate: validateActiveSlot
                )
                let recordsByProvider = Dictionary(grouping: records, by: \.provider)
                let slotsByProvider = Dictionary(grouping: slots, by: \.provider)
                let counts = try globalRecordCounts(
                    database: database,
                    providers: providers
                )
                return Dictionary(uniqueKeysWithValues: providers.map { provider in
                    (
                        provider,
                        BoundedRecentSnapshot(
                            snapshot: Snapshot(
                                records: recordsByProvider[provider] ?? [],
                                activeSlots: slotsByProvider[provider] ?? []
                            ),
                            totalRecordCount: counts[provider] ?? 0
                        )
                    )
                })
            }
        }
    }

    private func validateGlobalListRecordPayloads(
        database: OpaquePointer,
        providers: [String],
        validate: (String, Record) throws -> Void
    ) throws {
        let placeholders = selectedProviderPlaceholders(count: providers.count)
        let statement = try prepare(
            database,
            """
            SELECT provider, session_id, updated_at, writer_generation, record_json
            FROM agent_sessions
            WHERE provider IN (\(placeholders))
            ORDER BY provider ASC, session_id ASC
            """
        )
        defer { sqlite3_finalize(statement) }
        try bindSelectedProviders(providers, to: statement)
        while try stepRow(
            statement,
            database: database,
            operation: "validate global bounded list sessions"
        ) {
            guard let provider = text(statement, column: 0),
                  let sessionID = text(statement, column: 1),
                  let json = data(statement, column: 4) else {
                throw corruptRowError(operation: "validate global bounded list sessions")
            }
            let record = Record(
                provider: provider,
                sessionID: sessionID,
                updatedAt: sqlite3_column_double(statement, 2),
                writerGeneration: Int(sqlite3_column_int64(statement, 3)),
                json: json
            )
            try autoreleasepool { try validate(provider, record) }
        }
    }

    private func readGloballyBoundedListRecords(
        database: OpaquePointer,
        providers: [String],
        limit: Int
    ) throws -> [Record] {
        guard limit > 0 else { return [] }
        let placeholders = selectedProviderPlaceholders(count: providers.count)
        let limitIndex = providers.count + 1
        let statement = try prepare(
            database,
            """
            SELECT session.provider, session.session_id, session.updated_at,
                   session.writer_generation, session.record_json,
                   CASE
                     WHEN json_type(session.record_json, '$.runs') = 'array'
                          AND json_array_length(session.record_json, '$.runs') > 0
                     THEN COALESCE(
                       (
                         SELECT MAX(CAST(json_extract(run.value, '$.updatedAt') AS REAL))
                         FROM json_each(session.record_json, '$.runs') AS run
                         WHERE json_extract(run.value, '$.runId') =
                               json_extract(session.record_json, '$.activeRunId')
                       ),
                       (
                         SELECT MAX(CAST(json_extract(run.value, '$.updatedAt') AS REAL))
                         FROM json_each(session.record_json, '$.runs') AS run
                       ),
                       CAST(json_extract(session.record_json, '$.updatedAt') AS REAL)
                     )
                     ELSE CAST(json_extract(session.record_json, '$.updatedAt') AS REAL)
                   END AS list_updated_at
            FROM agent_sessions AS session
            WHERE session.provider IN (\(placeholders))
            ORDER BY list_updated_at DESC, session.session_id ASC, session.provider ASC
            LIMIT ?\(limitIndex)
            """
        )
        defer { sqlite3_finalize(statement) }
        try bindSelectedProviders(providers, to: statement)
        sqlite3_bind_int64(statement, Int32(limitIndex), sqlite3_int64(limit))
        var records: [Record] = []
        records.reserveCapacity(min(limit, 1_024))
        while try stepRow(
            statement,
            database: database,
            operation: "read global bounded list sessions"
        ) {
            guard let provider = text(statement, column: 0),
                  let sessionID = text(statement, column: 1),
                  let json = data(statement, column: 4) else {
                throw corruptRowError(operation: "read global bounded list sessions")
            }
            records.append(Record(
                provider: provider,
                sessionID: sessionID,
                updatedAt: sqlite3_column_double(statement, 2),
                writerGeneration: Int(sqlite3_column_int64(statement, 3)),
                json: json
            ))
        }
        return records
    }

    private func globalRecordCounts(
        database: OpaquePointer,
        providers: [String]
    ) throws -> [String: Int] {
        let placeholders = selectedProviderPlaceholders(count: providers.count)
        let statement = try prepare(
            database,
            """
            SELECT provider, COUNT(*) FROM agent_sessions
            WHERE provider IN (\(placeholders))
            GROUP BY provider
            """
        )
        defer { sqlite3_finalize(statement) }
        try bindSelectedProviders(providers, to: statement)
        var counts: [String: Int] = [:]
        while try stepRow(
            statement,
            database: database,
            operation: "count global bounded list sessions"
        ) {
            guard let provider = text(statement, column: 0) else {
                throw corruptRowError(operation: "count global bounded list sessions")
            }
            counts[provider] = Int(sqlite3_column_int64(statement, 1))
        }
        return counts
    }

    private func readGlobalListSlots(
        database: OpaquePointer,
        providers: [String],
        selectedSessionIDs: [String: Set<String>],
        validate: ((String, ActiveSlot) throws -> Void)?
    ) throws -> [ActiveSlot] {
        let placeholders = selectedProviderPlaceholders(count: providers.count)
        let statement = try prepare(
            database,
            """
            SELECT slot.provider, slot.scope, slot.scope_id, slot.session_id,
                   slot.updated_at, slot.writer_generation, slot.record_json,
                   json_valid(slot.record_json),
                   CASE WHEN json_valid(slot.record_json)
                        THEN json_extract(slot.record_json, '$.sessionId') END,
                   owner.session_id, owner.workspace_id, owner.surface_id,
                   CASE WHEN json_valid(owner.record_json)
                        THEN json_extract(owner.record_json, '$.workspaceId') END,
                   CASE WHEN json_valid(owner.record_json)
                        THEN json_extract(owner.record_json, '$.surfaceId') END,
                   CASE WHEN json_valid(slot.record_json)
                        THEN json_type(slot.record_json, '$.updatedAt') END
            FROM agent_active_slots AS slot
            LEFT JOIN agent_sessions AS owner
              ON owner.provider = slot.provider
             AND owner.session_id = slot.session_id
            WHERE slot.provider IN (\(placeholders))
            ORDER BY slot.provider ASC, slot.scope ASC, slot.scope_id ASC
            """
        )
        defer { sqlite3_finalize(statement) }
        try bindSelectedProviders(providers, to: statement)
        var slots: [ActiveSlot] = []
        while try stepRow(
            statement,
            database: database,
            operation: "read global bounded list slots"
        ) {
            guard let provider = text(statement, column: 0),
                  let rawScope = text(statement, column: 1),
                  let scope = Scope(rawValue: rawScope),
                  let scopeID = text(statement, column: 2),
                  let sessionID = text(statement, column: 3),
                  sqlite3_column_int64(statement, 7) == 1,
                  text(statement, column: 8) == sessionID,
                  text(statement, column: 9) == sessionID,
                  let slotUpdatedType = text(statement, column: 14),
                  ["integer", "real"].contains(slotUpdatedType),
                  let json = data(statement, column: 6) else {
                throw HookListProjectionValidationError(
                    provider: text(statement, column: 0) ?? "unknown"
                )
            }
            let ownerMatchesScope = switch scope {
            case .workspace:
                text(statement, column: 10) == scopeID
                    && text(statement, column: 12) == scopeID
            case .surface:
                text(statement, column: 11) == scopeID
                    && text(statement, column: 13) == scopeID
            }
            guard ownerMatchesScope else {
                throw HookListProjectionValidationError(provider: provider)
            }
            let slot = ActiveSlot(
                provider: provider,
                scope: scope,
                scopeID: scopeID,
                sessionID: sessionID,
                updatedAt: sqlite3_column_double(statement, 4),
                writerGeneration: Int(sqlite3_column_int64(statement, 5)),
                json: json
            )
            if let validate {
                try autoreleasepool { try validate(provider, slot) }
            }
            guard selectedSessionIDs[provider]?.contains(sessionID) == true else {
                continue
            }
            slots.append(slot)
        }
        return slots
    }

    private func selectedProviderPlaceholders(count: Int) -> String {
        precondition(count > 0)
        return (1...count).map { "?\($0)" }.joined(separator: ", ")
    }

    private func bindSelectedProviders(
        _ providers: [String],
        to statement: OpaquePointer
    ) throws {
        for (offset, provider) in providers.enumerated() {
            try bind(provider, to: Int32(offset + 1), in: statement)
        }
    }

    private func uniqueInspectionSources(_ sources: [LegacySource]) -> [LegacySource] {
        Dictionary(
            sources.map { ($0.provider, $0) },
            uniquingKeysWith: { _, latest in latest }
        ).values.sorted { $0.provider < $1.provider }
    }

    private func validatedInspectionAdmissions(
        sources: [LegacySource],
        admissions: [HookLegacySourceAdmission]
    ) throws -> [HookLegacySourceAdmission] {
        let sourceByProvider = Dictionary(uniqueKeysWithValues: sources.map { ($0.provider, $0) })
        var seenProviders: Set<String> = []
        return try admissions.sorted {
            $0.source.provider < $1.source.provider
        }.map { admission in
            guard seenProviders.insert(admission.source.provider).inserted,
                admission.wasIssuedByHookLegacyScanner,
                let source = sourceByProvider[admission.source.provider],
                source.url.standardizedFileURL == admission.source.url.standardizedFileURL,
                URL(fileURLWithPath: admission.stamp.path).standardizedFileURL
                    == admission.source.url.standardizedFileURL,
                admission.stamp.size == Int64(admission.json.count)
            else {
                throw HookLegacySourceImportError(provider: admission.source.provider)
            }
            return admission
        }
    }

    /// Decode and replace one compatibility provider at a time. The admissions
    /// retain all bounded source bytes, but only one Foundation object graph is
    /// live in addition to those bytes.
    private func importAdmittedLegacy(
        database: OpaquePointer,
        admissions: [HookLegacySourceAdmission]
    ) throws {
        for admission in admissions {
            do {
                try autoreleasepool {
                    let payload = try legacyPayload(
                        provider: admission.source.provider,
                        json: admission.json
                    )
                    try replaceLegacy(
                        database: database,
                        provider: admission.source.provider,
                        stamp: admission.stamp,
                        payload: payload
                    )
                }
            } catch {
                throw HookLegacySourceImportError(provider: admission.source.provider)
            }
        }
    }

    private func inspectionTransaction<T>(
        _ database: OpaquePointer,
        needsWrite: Bool,
        body: () throws -> T
    ) throws -> T {
        if needsWrite {
            return try transaction(database, body: body)
        }
        return try readTransaction(database, body: body)
    }

    private func validateAdmittedInspectionStorage(
        database: OpaquePointer,
        providers: [String],
        maximumRecordBytes: Int64,
        maximumProviderBytes: Int64,
        maximumSelectionBytes: Int64
    ) throws {
        let maximumRecordBytes = max(0, maximumRecordBytes)
        let maximumProviderBytes = max(0, maximumProviderBytes)
        let maximumSelectionBytes = max(0, maximumSelectionBytes)
        var selectedBytes: Int64 = 0
        for provider in providers {
            let metrics = try hookStorageMetrics(database: database, provider: provider)
            guard metrics.largestRecordBytes <= maximumRecordBytes else {
                throw HookInspectionStorageLimitError(
                    scope: .record,
                    provider: provider,
                    sessionID: metrics.largestRecordSessionID,
                    observed: metrics.largestRecordBytes,
                    maximum: maximumRecordBytes
                )
            }
            guard metrics.totalBytes <= maximumProviderBytes else {
                throw HookInspectionStorageLimitError(
                    scope: .provider,
                    provider: provider,
                    observed: metrics.totalBytes,
                    maximum: maximumProviderBytes
                )
            }
            let next = selectedBytes.addingReportingOverflow(metrics.totalBytes)
            selectedBytes = next.overflow ? .max : next.partialValue
            guard selectedBytes <= maximumSelectionBytes else {
                throw HookInspectionStorageLimitError(
                    scope: .selection,
                    provider: provider,
                    observed: selectedBytes,
                    maximum: maximumSelectionBytes
                )
            }
        }
    }
}
