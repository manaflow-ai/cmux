public import Foundation
import Darwin
import SQLite3

extension CmuxAgentSessionRegistry {
    /// Largest encoded canonical session record accepted from any writer.
    public static let maximumHookRecordBytes = 4 * 1_024 * 1_024
    /// Largest encoded record-plus-slot footprint accepted for one provider.
    public static let maximumHookProviderBytes = 64 * 1_024 * 1_024
    /// Largest encoded compatibility projection published for an older writer.
    public static let maximumHookLegacyProjectionBytes = 64 * 1_024 * 1_024
    /// Largest compatibility projection that inspection readers can scan.
    public static let maximumHookLegacyProjectionRecords = 20_000

    /// A canonical hook write exceeded a durable storage boundary.
    public struct HookStorageLimitError: Error, Equatable, Sendable {
        /// Storage resource that exceeded its boundary.
        public enum Scope: String, Equatable, Sendable {
            /// One canonical session row.
            case record
            /// All canonical rows for one provider.
            case provider
            /// The compatibility JSON projection.
            case legacyProjection = "legacy_projection"
        }

        /// Limit category.
        public var scope: Scope
        /// Provider associated with the failure.
        public var provider: String
        /// Session associated with a record-local failure.
        public var sessionID: String?
        /// Minimum observed byte count.
        public var observedBytes: Int64
        /// Largest accepted byte count.
        public var maximumBytes: Int64

        /// Creates a canonical storage-limit failure.
        public init(
            scope: Scope,
            provider: String,
            sessionID: String? = nil,
            observedBytes: Int64,
            maximumBytes: Int64
        ) {
            self.scope = scope
            self.provider = provider
            self.sessionID = sessionID
            self.observedBytes = observedBytes
            self.maximumBytes = maximumBytes
        }
    }

    /// A compatibility JSON file exceeded the bounded-read allocation limit.
    public struct HookLegacySourceSizeError: Error, Sendable {
        /// Path of the compatibility file.
        public var path: String
        /// File size observed through the open descriptor.
        public var observedBytes: Int64
        /// Largest accepted file size.
        public var maximumBytes: Int64

        /// Creates a bounded-read failure.
        public init(path: String, observedBytes: Int64, maximumBytes: Int64) {
            self.path = path
            self.observedBytes = observedBytes
            self.maximumBytes = maximumBytes
        }
    }

    /// Allocation-free size metadata used before inspection commands
    /// materialize a provider snapshot.
    public struct HookStorageMetrics: Equatable, Sendable {
        /// Number of canonical session rows for the provider.
        public var recordCount: Int
        /// Encoded bytes across canonical session rows.
        public var recordBytes: Int64
        /// Encoded bytes across canonical active slots.
        public var activeSlotBytes: Int64
        /// Session owning the largest encoded record, if any.
        public var largestRecordSessionID: String?
        /// Encoded size of `largestRecordSessionID`.
        public var largestRecordBytes: Int64

        /// Creates allocation metadata for one provider.
        public init(
            recordCount: Int,
            recordBytes: Int64,
            activeSlotBytes: Int64,
            largestRecordSessionID: String?,
            largestRecordBytes: Int64
        ) {
            self.recordCount = recordCount
            self.recordBytes = recordBytes
            self.activeSlotBytes = activeSlotBytes
            self.largestRecordSessionID = largestRecordSessionID
            self.largestRecordBytes = largestRecordBytes
        }

        /// Encoded bytes that a full provider snapshot would materialize.
        public var totalBytes: Int64 { recordBytes + activeSlotBytes }
    }

    /// A full provider snapshot exceeded a caller-supplied materialization
    /// boundary. Exact `hookRecord` reads remain available when this happens.
    public struct HookSnapshotLimitError: Error, Equatable, Sendable {
        /// Materialized resource that exceeded its boundary.
        public enum Scope: String, Equatable, Sendable {
            /// Number of canonical session rows.
            case records
            /// Largest encoded canonical session row.
            case recordBytes = "record_bytes"
            /// Total encoded record-plus-slot bytes for the provider.
            case providerBytes = "provider_bytes"
        }

        /// Limit category.
        public var scope: Scope
        /// Provider associated with the failure.
        public var provider: String
        /// Session associated with a record-local failure.
        public var sessionID: String?
        /// Minimum observed count or byte size.
        public var observed: Int64
        /// Largest accepted count or byte size.
        public var maximum: Int64

        /// Creates a bounded snapshot failure.
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

    /// Reads provider allocation metadata without selecting any JSON blobs.
    public func hookStorageMetrics(provider: String) throws -> HookStorageMetrics {
        try withDatabase { database in
            try ensureHookHotPathSchema(database)
            return try readTransaction(database) {
                try hookStorageMetrics(database: database, provider: provider)
            }
        }
    }

    /// Reads a complete provider snapshot only after validating its row and
    /// byte footprint in the same SQLite read transaction. This closes the
    /// check-then-materialize race for app inspection surfaces while retaining
    /// the full canonical history beyond the 256-row compatibility projection.
    public func hookBoundedSnapshot(
        provider: String,
        maximumRecords: Int = 20_000,
        maximumProviderBytes: Int64 = Int64(maximumHookProviderBytes),
        maximumRecordBytes: Int64 = Int64(maximumHookRecordBytes)
    ) throws -> Snapshot {
        let maximumRecords = max(0, maximumRecords)
        let maximumProviderBytes = max(0, maximumProviderBytes)
        let maximumRecordBytes = max(0, maximumRecordBytes)
        return try withDatabase { database in
            try ensureHookHotPathSchema(database)
            return try readTransaction(database) {
                let metrics = try hookStorageMetrics(database: database, provider: provider)
                guard metrics.recordCount <= maximumRecords else {
                    throw HookSnapshotLimitError(
                        scope: .records,
                        provider: provider,
                        observed: Int64(metrics.recordCount),
                        maximum: Int64(maximumRecords)
                    )
                }
                guard metrics.largestRecordBytes <= maximumRecordBytes else {
                    throw HookSnapshotLimitError(
                        scope: .recordBytes,
                        provider: provider,
                        sessionID: metrics.largestRecordSessionID,
                        observed: metrics.largestRecordBytes,
                        maximum: maximumRecordBytes
                    )
                }
                guard metrics.totalBytes <= maximumProviderBytes else {
                    throw HookSnapshotLimitError(
                        scope: .providerBytes,
                        provider: provider,
                        observed: metrics.totalBytes,
                        maximum: maximumProviderBytes
                    )
                }
                return Snapshot(
                    records: try readRecords(database: database, provider: provider),
                    activeSlots: try readSlots(database: database, provider: provider)
                )
            }
        }
    }

    /// Reads every active-slot owner plus the newest inactive history that fits
    /// the caller's record and encoded-byte budgets. Active owners are never
    /// silently omitted: if they alone exceed either budget, this method throws
    /// `HookSnapshotLimitError`. The selection and rows share one read
    /// transaction and use the provider/projection and slot-owner indexes.
    public func hookBoundedRecentRecords(
        provider: String,
        maximumRecords: Int,
        maximumBytes: Int64 = Int64(maximumHookProviderBytes)
    ) throws -> [Record] {
        let maximumRecords = max(0, maximumRecords)
        let maximumBytes = max(0, maximumBytes)
        return try withDatabase { database in
            try ensureHookHotPathSchema(database)
            return try readTransaction(database) {
                let activeTotals = try prepare(
                    database,
                    """
                    SELECT COUNT(*), COALESCE(SUM(length(session.record_json)), 0)
                    FROM agent_sessions AS session
                    WHERE session.provider = ?1
                      AND EXISTS (
                          SELECT 1 FROM agent_active_slots AS slot
                          WHERE slot.provider = session.provider
                            AND slot.session_id = session.session_id
                      )
                    """
                )
                defer { sqlite3_finalize(activeTotals) }
                try bind(provider, to: 1, in: activeTotals)
                guard try stepRow(
                    activeTotals,
                    database: database,
                    operation: "read active hook record totals"
                ) else {
                    throw corruptRowError(operation: "read active hook record totals")
                }
                let activeCount = Int(sqlite3_column_int64(activeTotals, 0))
                let activeBytes = sqlite3_column_int64(activeTotals, 1)
                guard activeCount <= maximumRecords else {
                    throw HookSnapshotLimitError(
                        scope: .records,
                        provider: provider,
                        observed: Int64(activeCount),
                        maximum: Int64(maximumRecords)
                    )
                }
                guard activeBytes <= maximumBytes else {
                    throw HookSnapshotLimitError(
                        scope: .providerBytes,
                        provider: provider,
                        observed: activeBytes,
                        maximum: maximumBytes
                    )
                }

                var records = try hookRecordsByActivity(
                    database: database,
                    provider: provider,
                    active: true,
                    limit: activeCount,
                    maximumBytes: activeBytes
                )
                let remainingCount = maximumRecords - records.count
                guard remainingCount > 0, activeBytes < maximumBytes else {
                    return records
                }
                let inactive = try hookRecordsByActivity(
                    database: database,
                    provider: provider,
                    active: false,
                    limit: remainingCount,
                    maximumBytes: maximumBytes - activeBytes
                )
                records.reserveCapacity(records.count + inactive.count)
                records.append(contentsOf: inactive)
                return records
            }
        }
    }

    private func hookRecordsByActivity(
        database: OpaquePointer,
        provider: String,
        active: Bool,
        limit: Int,
        maximumBytes: Int64
    ) throws -> [Record] {
        guard limit > 0, maximumBytes >= 0 else { return [] }
        let activityPredicate = active ? "EXISTS" : "NOT EXISTS"
        let statement = try prepare(
            database,
            """
            SELECT session.session_id, session.updated_at,
                   session.writer_generation, session.record_json
            FROM agent_sessions AS session
            WHERE session.provider = ?1
              AND \(activityPredicate) (
                  SELECT 1 FROM agent_active_slots AS slot
                  WHERE slot.provider = session.provider
                    AND slot.session_id = session.session_id
              )
            ORDER BY session.updated_at DESC, session.session_id ASC
            LIMIT ?2
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(provider, to: 1, in: statement)
        sqlite3_bind_int64(statement, 2, sqlite3_int64(limit))
        var records: [Record] = []
        records.reserveCapacity(limit)
        var selectedBytes: Int64 = 0
        while try stepRow(statement, database: database, operation: "read bounded hook records") {
            let blobBytes = Int64(sqlite3_column_bytes(statement, 3))
            let nextBytes = selectedBytes.addingReportingOverflow(blobBytes)
            guard !nextBytes.overflow, nextBytes.partialValue <= maximumBytes else {
                break
            }
            guard let sessionID = text(statement, column: 0),
                  let json = data(statement, column: 3) else {
                throw corruptRowError(operation: "read bounded hook records")
            }
            selectedBytes = nextBytes.partialValue
            records.append(Record(
                provider: provider,
                sessionID: sessionID,
                updatedAt: sqlite3_column_double(statement, 1),
                writerGeneration: Int(sqlite3_column_int64(statement, 2)),
                json: json
            ))
        }
        return records
    }

    private func hookStorageMetrics(
        database: OpaquePointer,
        provider: String
    ) throws -> HookStorageMetrics {
        let totals = try prepare(
            database,
            """
            SELECT COUNT(*), COALESCE(SUM(length(record_json)), 0)
            FROM agent_sessions WHERE provider = ?1
            """
        )
        defer { sqlite3_finalize(totals) }
        try bind(provider, to: 1, in: totals)
        guard try stepRow(totals, database: database, operation: "read hook storage totals") else {
            throw corruptRowError(operation: "read hook storage totals")
        }
        let recordCount = Int(sqlite3_column_int64(totals, 0))
        let recordBytes = sqlite3_column_int64(totals, 1)

        let largest = try prepare(
            database,
            """
            SELECT session_id, length(record_json)
            FROM agent_sessions
            WHERE provider = ?1
            ORDER BY length(record_json) DESC, session_id ASC
            LIMIT 1
            """
        )
        defer { sqlite3_finalize(largest) }
        try bind(provider, to: 1, in: largest)
        let hasLargest = try stepRow(
            largest,
            database: database,
            operation: "read largest hook record"
        )
        let largestSessionID = hasLargest ? text(largest, column: 0) : nil
        let largestBytes = hasLargest ? sqlite3_column_int64(largest, 1) : 0

        let slots = try prepare(
            database,
            """
            SELECT COALESCE(SUM(length(record_json)), 0)
            FROM agent_active_slots WHERE provider = ?1
            """
        )
        defer { sqlite3_finalize(slots) }
        try bind(provider, to: 1, in: slots)
        guard try stepRow(slots, database: database, operation: "read hook slot storage") else {
            throw corruptRowError(operation: "read hook slot storage")
        }
        return HookStorageMetrics(
            recordCount: recordCount,
            recordBytes: recordBytes,
            activeSlotBytes: sqlite3_column_int64(slots, 0),
            largestRecordSessionID: largestSessionID,
            largestRecordBytes: largestBytes
        )
    }

    /// Rejects an oversized caller-owned batch before opening SQLite or
    /// appending its blobs to the WAL. Reconciliation handles existing history;
    /// this bound prevents one API call from creating an unbounded transient
    /// database even when the transaction will ultimately roll back.
    func validateHookWriteBatch(
        provider: String,
        records: [Record],
        activeSlots: [ActiveSlot]
    ) throws {
        for record in records where record.json.count > Self.maximumHookRecordBytes {
            throw HookStorageLimitError(
                scope: .record,
                provider: provider,
                sessionID: record.sessionID,
                observedBytes: Int64(record.json.count),
                maximumBytes: Int64(Self.maximumHookRecordBytes)
            )
        }
        var observedBytes: Int64 = 0
        func include(_ count: Int) throws {
            let addition = observedBytes.addingReportingOverflow(Int64(count))
            observedBytes = addition.overflow ? .max : addition.partialValue
            guard observedBytes <= Int64(Self.maximumHookProviderBytes) else {
                throw HookStorageLimitError(
                    scope: .provider,
                    provider: provider,
                    observedBytes: observedBytes,
                    maximumBytes: Int64(Self.maximumHookProviderBytes)
                )
            }
        }
        for record in records { try include(record.json.count) }
        for slot in activeSlots { try include(slot.json.count) }
    }

    /// Reads one session row through its provider/session primary key.
    public func hookRecord(provider: String, sessionID: String) throws -> Record? {
        try withDatabase { database in
            try ensureHookHotPathSchema(database)
            return try readTransaction(database) {
                try readRecord(database: database, provider: provider, sessionID: sessionID)
            }
        }
    }

    /// Reads the exact workspace and surface slots used by a hook decision,
    /// plus the records referenced by those slots.
    ///
    /// - Returns: The scoped snapshot and deterministic row-read counts.
    public func hookActiveContext(
        provider: String,
        workspaceID: String,
        surfaceID: String?
    ) throws -> (snapshot: Snapshot, recordsRead: Int, slotsRead: Int) {
        try withDatabase { database in
            try ensureHookHotPathSchema(database)
            return try readTransaction(database) {
                var slots: [ActiveSlot] = []
                if let slot = try readSlot(
                    database: database,
                    provider: provider,
                    scope: .workspace,
                    scopeID: workspaceID
                ) {
                    slots.append(slot)
                }
                if let surfaceID,
                   let slot = try readSlot(
                    database: database,
                    provider: provider,
                    scope: .surface,
                    scopeID: surfaceID
                   ),
                   !slots.contains(where: { $0.scope == slot.scope && $0.scopeID == slot.scopeID }) {
                    slots.append(slot)
                }

                let sessionIDs = Set(slots.map(\.sessionID))
                let records = try sessionIDs.compactMap { sessionID in
                    try readRecord(database: database, provider: provider, sessionID: sessionID)
                }
                return (
                    Snapshot(records: records, activeSlots: slots),
                    records.count,
                    slots.count
                )
            }
        }
    }

    /// Reads incomplete fallback candidates through the indexed panel columns.
    /// A surface lookup returns at most the newest candidate; a workspace-only
    /// lookup returns at most two rows so callers can reject ambiguity.
    public func hookFallbackRecords(
        provider: String,
        workspaceID: String?,
        surfaceID: String?
    ) throws -> [Record] {
        guard workspaceID != nil || surfaceID != nil else { return [] }
        return try withDatabase { database in
            try ensureHookHotPathSchema(database)
            let predicates: String
            let limit: Int32
            if surfaceID != nil {
                predicates = "surface_id = ?2"
                limit = 1
            } else {
                predicates = "workspace_id = ?2"
                limit = 2
            }
            let statement = try prepare(
                database,
                """
                SELECT session_id, updated_at, writer_generation, record_json
                FROM agent_sessions
                WHERE provider = ?1 AND \(predicates)
                  AND completed_at IS NULL
                  AND COALESCE(json_extract(record_json, '$.sessionState'), '') != 'ended'
                ORDER BY updated_at DESC, session_id ASC
                LIMIT ?3
                """
            )
            defer { sqlite3_finalize(statement) }
            try bind(provider, to: 1, in: statement)
            try bind(surfaceID ?? workspaceID, to: 2, in: statement)
            sqlite3_bind_int(statement, 3, limit)
            var records: [Record] = []
            while try stepRow(statement, database: database, operation: "read hook fallback sessions") {
                guard let sessionID = text(statement, column: 0),
                      let json = data(statement, column: 3) else {
                    throw corruptRowError(operation: "read hook fallback sessions")
                }
                records.append(Record(
                    provider: provider,
                    sessionID: sessionID,
                    updatedAt: sqlite3_column_double(statement, 1),
                    writerGeneration: Int(sqlite3_column_int64(statement, 2)),
                    json: json
                ))
            }
            return records
        }
    }

    /// Reads running candidates through the indexed runtime-state expression.
    /// Process liveness checks intentionally happen after this SQLite read so a
    /// slow or recycled PID never extends a writer transaction.
    public func hookRunningRecords(
        provider: String,
        workspaceID: String,
        surfaceID: String?
    ) throws -> [Record] {
        try withDatabase { database in
            try ensureHookHotPathSchema(database)
            let surfacePredicate = surfaceID == nil ? "" : "AND surface_id = ?3"
            let statement = try prepare(
                database,
                """
                SELECT session_id, updated_at, writer_generation, record_json
                FROM agent_sessions
                WHERE provider = ?1 AND workspace_id = ?2
                  \(surfacePredicate)
                  AND json_extract(record_json, '$.runtimeStatus') = 'running'
                ORDER BY updated_at DESC, session_id ASC
                """
            )
            defer { sqlite3_finalize(statement) }
            try bind(provider, to: 1, in: statement)
            try bind(workspaceID, to: 2, in: statement)
            if let surfaceID { try bind(surfaceID, to: 3, in: statement) }
            var records: [Record] = []
            while try stepRow(statement, database: database, operation: "read running hook sessions") {
                guard let sessionID = text(statement, column: 0),
                      let json = data(statement, column: 3) else {
                    throw corruptRowError(operation: "read running hook sessions")
                }
                records.append(Record(
                    provider: provider,
                    sessionID: sessionID,
                    updatedAt: sqlite3_column_double(statement, 1),
                    writerGeneration: Int(sqlite3_column_int64(statement, 2)),
                    json: json
                ))
            }
            return records
        }
    }

    /// Mutates one hook session and only its owned or explicitly addressed
    /// active slots. Decoding and transformation run outside the writer
    /// transaction. The commit validates only touched rows and retries a
    /// conflicting generation within the registry's bounded contention policy.
    ///
    /// - Parameter sessionID: The only session row the closure may add, update,
    ///   or delete.
    /// - Parameter activeSlots: Destination slots whose current owners must be
    ///   included in the optimistic comparison.
    /// - Parameter includeOwnedSlots: Whether to load every slot currently owned
    ///   by `sessionID`, used by stop and consume transitions.
    /// - Returns: The closure result, committed provider revision, and exact
    ///   operation counts for deterministic performance tests.
    public func mutateHookSession<T>(
        provider: String,
        sessionID: String,
        activeSlots: Set<ActiveSlotKey> = [],
        includeOwnedSlots: Bool = true,
        now: TimeInterval = Date().timeIntervalSince1970,
        _ mutate: (inout Snapshot) throws -> T
    ) throws -> (
        result: T,
        revision: Int64,
        recordsRead: Int,
        slotsRead: Int,
        recordsWritten: Int,
        slotsWritten: Int
    ) {
        var lastContentionError: (any Error)?
        for _ in 0..<Self.maximumMutationAttempts {
            let previous: Snapshot
            do {
                previous = try hookMutationContext(
                    provider: provider,
                    sessionID: sessionID,
                    activeSlots: activeSlots,
                    includeOwnedSlots: includeOwnedSlots
                )
            } catch {
                guard isRetryableMutationError(error) else { throw error }
                lastContentionError = error
                continue
            }

            var current = previous
            let result = try mutate(&current)
            guard current.records.allSatisfy({ $0.sessionID == sessionID }) else {
                throw mutationConflictError()
            }
            if let oversized = current.records.first(where: {
                $0.json.count > Self.maximumHookRecordBytes
            }) {
                throw HookStorageLimitError(
                    scope: .record,
                    provider: provider,
                    sessionID: oversized.sessionID,
                    observedBytes: Int64(oversized.json.count),
                    maximumBytes: Int64(Self.maximumHookRecordBytes)
                )
            }
            let previousRecord = previous.records.first { $0.sessionID == sessionID }
            let currentRecord = current.records.first { $0.sessionID == sessionID }
            let recordChanged = !recordsMatch(previousRecord, currentRecord)

            let previousSlots = Dictionary(uniqueKeysWithValues: previous.activeSlots.map {
                (Self.slotKey(scope: $0.scope, scopeID: $0.scopeID), $0)
            })
            let currentSlots = Dictionary(uniqueKeysWithValues: current.activeSlots.map {
                (Self.slotKey(scope: $0.scope, scopeID: $0.scopeID), $0)
            })
            let changedSlotKeys = Set(previousSlots.keys).union(currentSlots.keys).filter {
                !slotsMatch(previousSlots[$0], currentSlots[$0])
            }

            do {
                let revision = try persistHookMutation(
                    provider: provider,
                    sessionID: sessionID,
                    previousRecord: previousRecord,
                    currentRecord: currentRecord,
                    previousSlots: previousSlots,
                    currentSlots: currentSlots,
                    changedSlotKeys: Set(changedSlotKeys),
                    now: now
                )
                return (
                    result,
                    revision,
                    previous.records.count,
                    previous.activeSlots.count,
                    recordChanged ? 1 : 0,
                    changedSlotKeys.count
                )
            } catch {
                guard isRetryableMutationError(error) else { throw error }
                lastContentionError = error
            }
        }
        throw lastContentionError ?? mutationConflictError()
    }

    /// Returns a bounded compatibility projection and the exact registry
    /// revision represented by it. Every active-slot owner is included, plus
    /// the newest 256 inactive records. The canonical registry retains the full
    /// history. The row snapshot and revision share one read transaction; JSON
    /// encoding happens after that transaction is released.
    public func hookLegacyProjection(
        provider: String,
        preservingTopLevelJSON existingJSON: Data? = nil
    ) throws -> (revision: Int64, projectedRevision: Int64, json: Data) {
        let captured: (snapshot: Snapshot, revision: Int64, projectedRevision: Int64) = try withDatabase { database in
            try ensureHookHotPathSchema(database)
            return try readTransaction(database) {
                let metadata = try hookProviderRevision(database: database, provider: provider)
                let footprint = try hookLegacyProjectionFootprint(
                    database: database,
                    provider: provider
                )
                guard footprint.recordCount <= Self.maximumHookLegacyProjectionRecords else {
                    throw HookSnapshotLimitError(
                        scope: .records,
                        provider: provider,
                        observed: Int64(footprint.recordCount),
                        maximum: Int64(Self.maximumHookLegacyProjectionRecords)
                    )
                }
                guard footprint.totalBytes <= Int64(Self.maximumHookLegacyProjectionBytes) else {
                    throw HookStorageLimitError(
                        scope: .legacyProjection,
                        provider: provider,
                        observedBytes: footprint.totalBytes,
                        maximumBytes: Int64(Self.maximumHookLegacyProjectionBytes)
                    )
                }
                return (
                    Snapshot(
                        records: try hookLegacyProjectionRecords(
                            database: database,
                            provider: provider
                        ),
                        activeSlots: try readSlots(database: database, provider: provider)
                    ),
                    metadata.revision,
                    metadata.projectedRevision
                )
            }
        }

        var root = existingJSON.flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        } ?? [:]
        root["version"] = max(root["version"] as? Int ?? 0, 2)
        var sessions: [String: Any] = [:]
        sessions.reserveCapacity(captured.snapshot.records.count)
        for record in captured.snapshot.records {
            guard let object = try JSONSerialization.jsonObject(with: record.json) as? [String: Any],
                  object["sessionId"] as? String == record.sessionID else {
                throw corruptRowError(operation: "project hook session")
            }
            sessions[record.sessionID] = object
        }
        var workspaceSlots: [String: Any] = [:]
        var surfaceSlots: [String: Any] = [:]
        for slot in captured.snapshot.activeSlots {
            guard let object = try JSONSerialization.jsonObject(with: slot.json) as? [String: Any],
                  object["sessionId"] as? String == slot.sessionID else {
                throw corruptRowError(operation: "project hook active slot")
            }
            switch slot.scope {
            case .workspace: workspaceSlots[slot.scopeID] = object
            case .surface: surfaceSlots[slot.scopeID] = object
            }
        }
        root["sessions"] = sessions
        root["activeSessionsByWorkspace"] = workspaceSlots
        root["activeSessionsBySurface"] = surfaceSlots
        guard JSONSerialization.isValidJSONObject(root) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        let json = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        guard json.count <= Self.maximumHookLegacyProjectionBytes else {
            throw HookStorageLimitError(
                scope: .legacyProjection,
                provider: provider,
                observedBytes: Int64(json.count),
                maximumBytes: Int64(Self.maximumHookLegacyProjectionBytes)
            )
        }
        return (captured.revision, captured.projectedRevision, json)
    }

    /// Marks an atomically published compatibility file as representing the
    /// supplied registry revision. A newer commit can advance `revision` while
    /// this method runs, but `projectedRevision` never advances past the exact
    /// snapshot that was written.
    public func markHookLegacyProjection(
        provider: String,
        revision: Int64,
        stamp: LegacyStamp
    ) throws {
        try withDatabase { database in
            try ensureHookHotPathSchema(database)
            try transaction(database, retryBeginContention: false) {
                let statement = try prepare(
                    database,
                    """
                    INSERT INTO agent_provider_metadata (
                        provider, revision, projected_revision, last_pruned_at
                    ) VALUES (?1, 0, ?2, 0)
                    ON CONFLICT(provider) DO UPDATE SET
                        projected_revision = MAX(projected_revision, excluded.projected_revision)
                    """
                )
                defer { sqlite3_finalize(statement) }
                try bind(provider, to: 1, in: statement)
                sqlite3_bind_int64(statement, 2, revision)
                try stepDone(statement, database: database, operation: "mark hook legacy projection")
                try writeLegacyStamp(database: database, provider: provider, stamp: stamp)
            }
        }
    }

    /// Publishes the complete provider snapshot under the compatibility
    /// sidecar's cross-process lock and ensures `requiredRevision` is
    /// represented by the file. Lock acquisition is nonblocking so a stuck
    /// compatibility writer cannot stall a prompt hook indefinitely. A
    /// contending writer first rechecks the published revision and otherwise
    /// receives `EWOULDBLOCK`; the lock owner or a later hook converges the file.
    ///
    /// Cross-process `flock` is required here because Swift actors cannot
    /// serialize independent cmux and hook processes. The critical section is
    /// bounded to one snapshot encode, atomic rename, and revision mark.
    ///
    /// - Returns: The exact registry revision represented by the file.
    @discardableResult
    public func projectHookLegacyStore(
        provider: String,
        to stateURL: URL,
        including requiredRevision: Int64,
        fileManager: FileManager = .default
    ) throws -> Int64 {
        try projectHookLegacyStore(
            provider: provider,
            to: stateURL,
            including: requiredRevision,
            fileManager: fileManager,
            afterPublishing: {}
        )
    }

    @discardableResult
    func projectHookLegacyStore(
        provider: String,
        to stateURL: URL,
        including requiredRevision: Int64,
        fileManager: FileManager = .default,
        afterPublishing: () throws -> Void
    ) throws -> Int64 {
        let initialStatus = try hookProjectionStatus(provider: provider)
        if initialStatus.projectedRevision >= requiredRevision,
           let stamp = LegacyStamp.read(path: stateURL.path, fileManager: fileManager),
           try legacySourceIsCurrent(provider: provider, stamp: stamp) {
            return initialStatus.projectedRevision
        }
        try fileManager.createDirectory(
            at: stateURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        let descriptor = open(
            stateURL.path + ".lock",
            O_CREAT | O_RDWR,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { _ = flock(descriptor, LOCK_UN) }

        let existingData = try? readHookLegacySourceData(at: stateURL)
        let existingStamp = LegacyStamp.read(path: stateURL.path, fileManager: fileManager)
        let status = try hookProjectionStatus(provider: provider)
        if status.projectedRevision >= requiredRevision,
           let existingStamp,
           try legacySourceIsCurrent(provider: provider, stamp: existingStamp) {
            return status.projectedRevision
        }

        let projection = try hookLegacyProjection(
            provider: provider,
            preservingTopLevelJSON: existingData
        )
        guard projection.revision >= requiredRevision else {
            throw mutationConflictError()
        }
        try replaceHookLegacyFile(
            with: projection.json,
            at: stateURL,
            fileManager: fileManager
        )
        try afterPublishing()
        let stamp = try verifiedHookLegacyPublication(
            at: stateURL,
            expectedJSON: projection.json
        )
        try markHookLegacyProjection(
            provider: provider,
            revision: projection.revision,
            stamp: stamp
        )
        let finalStamp = try verifiedHookLegacyPublication(
            at: stateURL,
            expectedJSON: projection.json
        )
        guard finalStamp == stamp else { throw mutationConflictError() }
        return projection.revision
    }

    /// Reads the provider's current and projected compatibility revisions.
    public func hookProjectionStatus(provider: String) throws -> (revision: Int64, projectedRevision: Int64) {
        try withDatabase { database in
            try ensureHookHotPathSchema(database)
            return try hookProviderRevision(database: database, provider: provider)
        }
    }

    func ensureHookHotPathSchema(_ database: OpaquePointer) throws {
        if try schemaVersion(database) < 4 {
            try transaction(database, retryBeginContention: false) {
                guard try schemaVersion(database) < 4 else { return }
            try execute(
                database,
                sql: """
                CREATE TABLE IF NOT EXISTS agent_provider_metadata (
                    provider TEXT NOT NULL PRIMARY KEY,
                    revision INTEGER NOT NULL DEFAULT 0,
                    projected_revision INTEGER NOT NULL DEFAULT 0,
                    last_pruned_at REAL NOT NULL DEFAULT 0
                ) WITHOUT ROWID;
                INSERT OR IGNORE INTO agent_provider_metadata (
                    provider, revision, projected_revision, last_pruned_at
                )
                SELECT provider, 1, 0, 0 FROM agent_sessions GROUP BY provider;
                INSERT OR IGNORE INTO agent_provider_metadata (
                    provider, revision, projected_revision, last_pruned_at
                )
                SELECT provider, 1, 0, 0 FROM agent_active_slots GROUP BY provider;

                CREATE INDEX IF NOT EXISTS agent_sessions_retention
                    ON agent_sessions(provider, updated_at ASC, session_id ASC);
                CREATE INDEX IF NOT EXISTS agent_sessions_hook_projection
                    ON agent_sessions(provider, updated_at DESC, session_id ASC);
                CREATE INDEX IF NOT EXISTS agent_sessions_hook_workspace
                    ON agent_sessions(provider, workspace_id, updated_at DESC, session_id ASC);
                CREATE INDEX IF NOT EXISTS agent_sessions_hook_surface
                    ON agent_sessions(provider, surface_id, updated_at DESC, session_id ASC);
                DROP INDEX IF EXISTS agent_sessions_hook_running;
                CREATE INDEX agent_sessions_hook_running
                    ON agent_sessions(
                        provider,
                        workspace_id,
                        json_extract(record_json, '$.runtimeStatus'),
                        surface_id,
                        updated_at DESC,
                        session_id ASC
                    );
                CREATE INDEX IF NOT EXISTS agent_active_slots_owner
                    ON agent_active_slots(provider, session_id, scope, scope_id);

                CREATE TRIGGER IF NOT EXISTS agent_sessions_revision_insert
                AFTER INSERT ON agent_sessions BEGIN
                    INSERT INTO agent_provider_metadata (
                        provider, revision, projected_revision, last_pruned_at
                    ) VALUES (NEW.provider, 1, 0, 0)
                    ON CONFLICT(provider) DO UPDATE SET revision = revision + 1;
                END;
                CREATE TRIGGER IF NOT EXISTS agent_sessions_revision_update
                AFTER UPDATE ON agent_sessions BEGIN
                    INSERT INTO agent_provider_metadata (
                        provider, revision, projected_revision, last_pruned_at
                    ) VALUES (NEW.provider, 1, 0, 0)
                    ON CONFLICT(provider) DO UPDATE SET revision = revision + 1;
                END;
                CREATE TRIGGER IF NOT EXISTS agent_sessions_revision_delete
                AFTER DELETE ON agent_sessions BEGIN
                    INSERT INTO agent_provider_metadata (
                        provider, revision, projected_revision, last_pruned_at
                    ) VALUES (OLD.provider, 1, 0, 0)
                    ON CONFLICT(provider) DO UPDATE SET revision = revision + 1;
                END;
                CREATE TRIGGER IF NOT EXISTS agent_active_slots_revision_insert
                AFTER INSERT ON agent_active_slots BEGIN
                    INSERT INTO agent_provider_metadata (
                        provider, revision, projected_revision, last_pruned_at
                    ) VALUES (NEW.provider, 1, 0, 0)
                    ON CONFLICT(provider) DO UPDATE SET revision = revision + 1;
                END;
                CREATE TRIGGER IF NOT EXISTS agent_active_slots_revision_update
                AFTER UPDATE ON agent_active_slots BEGIN
                    INSERT INTO agent_provider_metadata (
                        provider, revision, projected_revision, last_pruned_at
                    ) VALUES (NEW.provider, 1, 0, 0)
                    ON CONFLICT(provider) DO UPDATE SET revision = revision + 1;
                END;
                CREATE TRIGGER IF NOT EXISTS agent_active_slots_revision_delete
                AFTER DELETE ON agent_active_slots BEGIN
                    INSERT INTO agent_provider_metadata (
                        provider, revision, projected_revision, last_pruned_at
                    ) VALUES (OLD.provider, 1, 0, 0)
                    ON CONFLICT(provider) DO UPDATE SET revision = revision + 1;
                END;
                PRAGMA user_version=4;
                """
                )
            }
        }
        if try schemaVersion(database) < 5 {
            try transaction(database, retryBeginContention: false) {
                guard try schemaVersion(database) < 5 else { return }
                try execute(
                    database,
                    sql: """
                    ALTER TABLE agent_provider_metadata
                        ADD COLUMN record_bytes INTEGER NOT NULL DEFAULT 0;
                    ALTER TABLE agent_provider_metadata
                        ADD COLUMN slot_bytes INTEGER NOT NULL DEFAULT 0;
                    UPDATE agent_provider_metadata SET
                        record_bytes = COALESCE((
                            SELECT SUM(length(record_json)) FROM agent_sessions
                            WHERE agent_sessions.provider = agent_provider_metadata.provider
                        ), 0),
                        slot_bytes = COALESCE((
                            SELECT SUM(length(record_json)) FROM agent_active_slots
                            WHERE agent_active_slots.provider = agent_provider_metadata.provider
                        ), 0);

                DROP TRIGGER IF EXISTS agent_sessions_revision_insert;
                DROP TRIGGER IF EXISTS agent_sessions_revision_update;
                DROP TRIGGER IF EXISTS agent_sessions_revision_delete;
                DROP TRIGGER IF EXISTS agent_active_slots_revision_insert;
                DROP TRIGGER IF EXISTS agent_active_slots_revision_update;
                DROP TRIGGER IF EXISTS agent_active_slots_revision_delete;

                CREATE TRIGGER agent_sessions_revision_insert
                AFTER INSERT ON agent_sessions BEGIN
                    INSERT INTO agent_provider_metadata (
                        provider, revision, projected_revision, last_pruned_at,
                        record_bytes, slot_bytes
                    ) VALUES (NEW.provider, 1, 0, 0, length(NEW.record_json), 0)
                    ON CONFLICT(provider) DO UPDATE SET
                        revision = revision + 1,
                        record_bytes = record_bytes + length(NEW.record_json);
                END;
                CREATE TRIGGER agent_sessions_revision_update
                AFTER UPDATE ON agent_sessions BEGIN
                    INSERT INTO agent_provider_metadata (
                        provider, revision, projected_revision, last_pruned_at,
                        record_bytes, slot_bytes
                    ) VALUES (
                        NEW.provider, 1, 0, 0,
                        length(NEW.record_json) - length(OLD.record_json), 0
                    )
                    ON CONFLICT(provider) DO UPDATE SET
                        revision = revision + 1,
                        record_bytes = record_bytes
                            + length(NEW.record_json) - length(OLD.record_json);
                END;
                CREATE TRIGGER agent_sessions_revision_delete
                AFTER DELETE ON agent_sessions BEGIN
                    INSERT INTO agent_provider_metadata (
                        provider, revision, projected_revision, last_pruned_at,
                        record_bytes, slot_bytes
                    ) VALUES (OLD.provider, 1, 0, 0, 0, 0)
                    ON CONFLICT(provider) DO UPDATE SET
                        revision = revision + 1,
                        record_bytes = MAX(0, record_bytes - length(OLD.record_json));
                END;
                CREATE TRIGGER agent_active_slots_revision_insert
                AFTER INSERT ON agent_active_slots BEGIN
                    INSERT INTO agent_provider_metadata (
                        provider, revision, projected_revision, last_pruned_at,
                        record_bytes, slot_bytes
                    ) VALUES (NEW.provider, 1, 0, 0, 0, length(NEW.record_json))
                    ON CONFLICT(provider) DO UPDATE SET
                        revision = revision + 1,
                        slot_bytes = slot_bytes + length(NEW.record_json);
                END;
                CREATE TRIGGER agent_active_slots_revision_update
                AFTER UPDATE ON agent_active_slots BEGIN
                    INSERT INTO agent_provider_metadata (
                        provider, revision, projected_revision, last_pruned_at,
                        record_bytes, slot_bytes
                    ) VALUES (
                        NEW.provider, 1, 0, 0, 0,
                        length(NEW.record_json) - length(OLD.record_json)
                    )
                    ON CONFLICT(provider) DO UPDATE SET
                        revision = revision + 1,
                        slot_bytes = slot_bytes
                            + length(NEW.record_json) - length(OLD.record_json);
                END;
                CREATE TRIGGER agent_active_slots_revision_delete
                AFTER DELETE ON agent_active_slots BEGIN
                    INSERT INTO agent_provider_metadata (
                        provider, revision, projected_revision, last_pruned_at,
                        record_bytes, slot_bytes
                    ) VALUES (OLD.provider, 1, 0, 0, 0, 0)
                    ON CONFLICT(provider) DO UPDATE SET
                        revision = revision + 1,
                        slot_bytes = MAX(0, slot_bytes - length(OLD.record_json));
                END;
                PRAGMA user_version=5;
                """
                )
                let oversized = try prepare(
                    database,
                    """
                    SELECT provider FROM agent_provider_metadata
                    WHERE record_bytes + slot_bytes > ?1 ORDER BY provider
                    """
                )
                defer { sqlite3_finalize(oversized) }
                sqlite3_bind_int64(oversized, 1, sqlite3_int64(Self.maximumHookProviderBytes))
                var oversizedProviders: [String] = []
                while try stepRow(oversized, database: database, operation: "read oversized providers") {
                    if let provider = text(oversized, column: 0) { oversizedProviders.append(provider) }
                }
                for provider in oversizedProviders {
                    try reconcileHookProviderStorageLimit(
                        database: database,
                        provider: provider,
                        protectedSessionIDs: [],
                        previousBytes: .max
                    )
                }
            }
        }
        guard try schemaVersion(database) < 6 else { return }
        try transaction(database, retryBeginContention: false) {
            guard try schemaVersion(database) < 6 else { return }
            try execute(
                database,
                sql: """
                ALTER TABLE agent_legacy_sources
                    ADD COLUMN quarantined INTEGER NOT NULL DEFAULT 0;
                PRAGMA user_version=6;
                """
            )
        }
    }

    private func hookMutationContext(
        provider: String,
        sessionID: String,
        activeSlots: Set<ActiveSlotKey>,
        includeOwnedSlots: Bool
    ) throws -> Snapshot {
        try withDatabase { database in
            try ensureHookHotPathSchema(database)
            return try readTransaction(database) {
                var records: [Record] = []
                if let record = try readRecord(
                    database: database,
                    provider: provider,
                    sessionID: sessionID
                ) {
                    records.append(record)
                }
                var slotsByKey: [String: ActiveSlot] = [:]
                if includeOwnedSlots {
                    for slot in try hookOwnedSlots(
                        database: database,
                        provider: provider,
                        sessionID: sessionID
                    ) {
                        slotsByKey[Self.slotKey(scope: slot.scope, scopeID: slot.scopeID)] = slot
                    }
                }
                for key in activeSlots {
                    if let slot = try readSlot(
                        database: database,
                        provider: provider,
                        scope: key.scope,
                        scopeID: key.scopeID
                    ) {
                        slotsByKey[Self.slotKey(scope: key.scope, scopeID: key.scopeID)] = slot
                    }
                }
                return Snapshot(records: records, activeSlots: Array(slotsByKey.values))
            }
        }
    }

    private func hookOwnedSlots(
        database: OpaquePointer,
        provider: String,
        sessionID: String
    ) throws -> [ActiveSlot] {
        let statement = try prepare(
            database,
            """
            SELECT scope, scope_id, updated_at, writer_generation, record_json
            FROM agent_active_slots
            WHERE provider = ?1 AND session_id = ?2
            ORDER BY scope, scope_id
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(provider, to: 1, in: statement)
        try bind(sessionID, to: 2, in: statement)
        var slots: [ActiveSlot] = []
        while try stepRow(statement, database: database, operation: "read owned hook slots") {
            guard let scopeValue = text(statement, column: 0),
                  let scope = Scope(rawValue: scopeValue),
                  let scopeID = text(statement, column: 1),
                  let json = data(statement, column: 4) else {
                throw corruptRowError(operation: "read owned hook slots")
            }
            slots.append(ActiveSlot(
                provider: provider,
                scope: scope,
                scopeID: scopeID,
                sessionID: sessionID,
                updatedAt: sqlite3_column_double(statement, 2),
                writerGeneration: Int(sqlite3_column_int64(statement, 3)),
                json: json
            ))
        }
        return slots
    }

    private func hookLegacyProjectionRecords(
        database: OpaquePointer,
        provider: String
    ) throws -> [Record] {
        let statement = try prepare(
            database,
            """
            WITH recent_inactive AS (
                SELECT session.session_id
                FROM agent_sessions AS session
                WHERE session.provider = ?1
                  AND NOT EXISTS (
                      SELECT 1
                      FROM agent_active_slots AS slot
                      WHERE slot.provider = session.provider
                        AND slot.session_id = session.session_id
                  )
                ORDER BY session.updated_at DESC, session.session_id ASC
                LIMIT 256
            )
            SELECT session.session_id,
                   session.updated_at,
                   session.writer_generation,
                   session.record_json
            FROM agent_sessions AS session
            WHERE session.provider = ?1
              AND (
                  EXISTS (
                      SELECT 1
                      FROM agent_active_slots AS slot
                      WHERE slot.provider = session.provider
                        AND slot.session_id = session.session_id
                  )
                  OR session.session_id IN (
                      SELECT session_id FROM recent_inactive
                  )
              )
            ORDER BY session.updated_at DESC, session.session_id ASC
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(provider, to: 1, in: statement)
        var records: [Record] = []
        while try stepRow(
            statement,
            database: database,
            operation: "read hook compatibility sessions"
        ) {
            guard let sessionID = text(statement, column: 0),
                  let json = data(statement, column: 3) else {
                throw corruptRowError(operation: "read hook compatibility sessions")
            }
            records.append(Record(
                provider: provider,
                sessionID: sessionID,
                updatedAt: sqlite3_column_double(statement, 1),
                writerGeneration: Int(sqlite3_column_int64(statement, 2)),
                json: json
            ))
        }
        return records
    }

    /// Counts the exact rows selected by `hookLegacyProjectionRecords` and all
    /// active-slot blobs before either query copies JSON into Swift memory.
    private func hookLegacyProjectionFootprint(
        database: OpaquePointer,
        provider: String
    ) throws -> (recordCount: Int, totalBytes: Int64) {
        let records = try prepare(
            database,
            """
            WITH recent_inactive AS (
                SELECT session.session_id
                FROM agent_sessions AS session
                WHERE session.provider = ?1
                  AND NOT EXISTS (
                      SELECT 1 FROM agent_active_slots AS slot
                      WHERE slot.provider = session.provider
                        AND slot.session_id = session.session_id
                  )
                ORDER BY session.updated_at DESC, session.session_id ASC
                LIMIT 256
            )
            SELECT COUNT(*), COALESCE(SUM(length(session.record_json)), 0)
            FROM agent_sessions AS session
            WHERE session.provider = ?1
              AND (
                  EXISTS (
                      SELECT 1 FROM agent_active_slots AS slot
                      WHERE slot.provider = session.provider
                        AND slot.session_id = session.session_id
                  )
                  OR session.session_id IN (SELECT session_id FROM recent_inactive)
              )
            """
        )
        defer { sqlite3_finalize(records) }
        try bind(provider, to: 1, in: records)
        guard try stepRow(
            records,
            database: database,
            operation: "read hook compatibility footprint"
        ) else {
            throw corruptRowError(operation: "read hook compatibility footprint")
        }
        let recordCount = Int(sqlite3_column_int64(records, 0))
        let recordBytes = sqlite3_column_int64(records, 1)

        let slots = try prepare(
            database,
            """
            SELECT COALESCE(SUM(length(record_json)), 0)
            FROM agent_active_slots WHERE provider = ?1
            """
        )
        defer { sqlite3_finalize(slots) }
        try bind(provider, to: 1, in: slots)
        guard try stepRow(
            slots,
            database: database,
            operation: "read hook compatibility slot footprint"
        ) else {
            throw corruptRowError(operation: "read hook compatibility slot footprint")
        }
        let slotBytes = sqlite3_column_int64(slots, 0)
        let total = recordBytes.addingReportingOverflow(slotBytes)
        return (recordCount, total.overflow ? .max : total.partialValue)
    }

    private func persistHookMutation(
        provider: String,
        sessionID: String,
        previousRecord: Record?,
        currentRecord: Record?,
        previousSlots: [String: ActiveSlot],
        currentSlots: [String: ActiveSlot],
        changedSlotKeys: Set<String>,
        now: TimeInterval
    ) throws -> Int64 {
        try withDatabase { database in
            try ensureHookHotPathSchema(database)
            return try transaction(database, retryBeginContention: false) {
                let previousProviderBytes = try hookProviderStorageBytes(
                    database: database,
                    provider: provider
                )
                guard recordsMatch(
                    try readRecord(database: database, provider: provider, sessionID: sessionID),
                    previousRecord
                ) else { throw mutationConflictError() }
                for key in changedSlotKeys {
                    guard let reference = previousSlots[key] ?? currentSlots[key],
                          slotsMatch(
                            try readSlot(
                                database: database,
                                provider: provider,
                                scope: reference.scope,
                                scopeID: reference.scopeID
                            ),
                            previousSlots[key]
                          ) else { throw mutationConflictError() }
                }

                if !recordsMatch(previousRecord, currentRecord) {
                    if var currentRecord {
                        currentRecord.provider = provider
                        try upsert(currentRecord, database: database)
                    } else {
                        try deleteSession(
                            database: database,
                            provider: provider,
                            sessionID: sessionID,
                            maximumWriterGeneration: Self.currentWriterGeneration
                        )
                    }
                }
                for key in changedSlotKeys {
                    if var slot = currentSlots[key] {
                        slot.provider = provider
                        try upsert(slot, database: database)
                    } else if let slot = previousSlots[key] {
                        try deleteSlot(
                            database: database,
                            provider: provider,
                            scope: slot.scope,
                            scopeID: slot.scopeID,
                            maximumWriterGeneration: Self.currentWriterGeneration
                        )
                    }
                }
                try maintainHookRowsIfNeeded(database: database, provider: provider, now: now)
                try reconcileHookProviderStorageLimit(
                    database: database,
                    provider: provider,
                    protectedSessionIDs: [sessionID],
                    previousBytes: previousProviderBytes
                )
                return try hookProviderRevision(database: database, provider: provider).revision
            }
        }
    }

    func hookProviderStorageBytes(
        database: OpaquePointer,
        provider: String
    ) throws -> Int64 {
        let statement = try prepare(
            database,
            """
            SELECT record_bytes + slot_bytes FROM agent_provider_metadata
            WHERE provider = ?1
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(provider, to: 1, in: statement)
        guard try stepRow(statement, database: database, operation: "read provider storage") else {
            return 0
        }
        return sqlite3_column_int64(statement, 0)
    }

    /// Removes oldest inactive current-generation history before rejecting a
    /// growing write. The touched session and every active/future-generation row
    /// survive. An already-oversized provider may make a non-growing transition,
    /// allowing stop/deactivation to recover a store migrated from an old build.
    func reconcileHookProviderStorageLimit(
        database: OpaquePointer,
        provider: String,
        protectedSessionIDs: Set<String>,
        previousBytes: Int64
    ) throws {
        var currentBytes = try hookProviderStorageBytes(database: database, provider: provider)
        guard currentBytes > Int64(Self.maximumHookProviderBytes) else { return }

        let candidates = try prepare(
            database,
            """
            SELECT session_id, length(record_json)
            FROM agent_sessions AS session
            WHERE provider = ?1 AND writer_generation <= ?2
              AND NOT EXISTS (
                  SELECT 1 FROM agent_active_slots AS slot
                  WHERE slot.provider = session.provider
                    AND slot.session_id = session.session_id
              )
            ORDER BY updated_at ASC, session_id ASC
            """
        )
        defer { sqlite3_finalize(candidates) }
        try bind(provider, to: 1, in: candidates)
        sqlite3_bind_int64(candidates, 2, sqlite3_int64(Self.currentWriterGeneration))
        var removable: [(sessionID: String, bytes: Int64)] = []
        while try stepRow(candidates, database: database, operation: "read storage prune candidates") {
            guard let sessionID = text(candidates, column: 0),
                  !protectedSessionIDs.contains(sessionID) else { continue }
            removable.append((sessionID, sqlite3_column_int64(candidates, 1)))
        }
        for candidate in removable where currentBytes > Int64(Self.maximumHookProviderBytes) {
            try deleteSession(
                database: database,
                provider: provider,
                sessionID: candidate.sessionID,
                maximumWriterGeneration: Self.currentWriterGeneration
            )
            currentBytes = max(0, currentBytes - candidate.bytes)
        }
        currentBytes = try hookProviderStorageBytes(database: database, provider: provider)
        guard currentBytes <= Int64(Self.maximumHookProviderBytes)
                || currentBytes <= previousBytes else {
            throw HookStorageLimitError(
                scope: .provider,
                provider: provider,
                observedBytes: currentBytes,
                maximumBytes: Int64(Self.maximumHookProviderBytes)
            )
        }
    }

    private func hookProviderRevision(
        database: OpaquePointer,
        provider: String
    ) throws -> (revision: Int64, projectedRevision: Int64) {
        let statement = try prepare(
            database,
            """
            SELECT revision, projected_revision FROM agent_provider_metadata
            WHERE provider = ?1
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(provider, to: 1, in: statement)
        guard try stepRow(statement, database: database, operation: "read hook provider revision") else {
            return (0, 0)
        }
        return (sqlite3_column_int64(statement, 0), sqlite3_column_int64(statement, 1))
    }

    private func maintainHookRowsIfNeeded(
        database: OpaquePointer,
        provider: String,
        now: TimeInterval
    ) throws {
        let metadata = try prepare(
            database,
            "SELECT last_pruned_at FROM agent_provider_metadata WHERE provider = ?1"
        )
        defer { sqlite3_finalize(metadata) }
        try bind(provider, to: 1, in: metadata)
        let lastPrunedAt: TimeInterval
        if try stepRow(metadata, database: database, operation: "read hook maintenance time") {
            lastPrunedAt = sqlite3_column_double(metadata, 0)
        } else {
            lastPrunedAt = 0
        }
        guard now - lastPrunedAt >= 60 else { return }

        let cutoff = now - (60 * 60 * 24 * 7)
        let expired = try prepare(
            database,
            """
            DELETE FROM agent_sessions
            WHERE provider = ?1 AND updated_at < ?2
              AND writer_generation <= ?3
              AND session_id NOT IN (
                  SELECT session_id FROM agent_active_slots WHERE provider = ?1
              )
            """
        )
        try bind(provider, to: 1, in: expired)
        sqlite3_bind_double(expired, 2, cutoff)
        sqlite3_bind_int64(expired, 3, sqlite3_int64(Self.currentWriterGeneration))
        try stepDone(expired, database: database, operation: "prune expired hook sessions")
        sqlite3_finalize(expired)

        let overflow = try prepare(
            database,
            """
            DELETE FROM agent_sessions
            WHERE provider = ?1 AND session_id IN (
                SELECT session_id FROM agent_sessions
                WHERE provider = ?1
                  AND writer_generation <= ?2
                  AND session_id NOT IN (
                      SELECT session_id FROM agent_active_slots WHERE provider = ?1
                  )
                ORDER BY updated_at ASC, session_id ASC
                LIMIT MAX(0, (
                    SELECT COUNT(*) - 10000 FROM agent_sessions WHERE provider = ?1
                ))
            )
            """
        )
        try bind(provider, to: 1, in: overflow)
        sqlite3_bind_int64(overflow, 2, sqlite3_int64(Self.currentWriterGeneration))
        try stepDone(overflow, database: database, operation: "cap hook sessions")
        sqlite3_finalize(overflow)

        let danglingSlots = try prepare(
            database,
            """
            DELETE FROM agent_active_slots AS slot
            WHERE slot.provider = ?1 AND (
                NOT EXISTS (
                    SELECT 1 FROM agent_sessions AS session
                    WHERE session.provider = slot.provider
                      AND session.session_id = slot.session_id
                )
                OR NOT EXISTS (
                    SELECT 1 FROM agent_sessions AS session
                    WHERE session.provider = slot.provider
                      AND session.session_id = slot.session_id
                      AND CASE slot.scope
                          WHEN 'workspace' THEN session.workspace_id = slot.scope_id
                          WHEN 'surface' THEN session.surface_id = slot.scope_id
                          ELSE 0
                      END
                )
            ) AND slot.writer_generation <= ?2
            """
        )
        try bind(provider, to: 1, in: danglingSlots)
        sqlite3_bind_int64(danglingSlots, 2, sqlite3_int64(Self.currentWriterGeneration))
        try stepDone(danglingSlots, database: database, operation: "prune dangling hook slots")
        sqlite3_finalize(danglingSlots)

        let mark = try prepare(
            database,
            """
            INSERT INTO agent_provider_metadata (
                provider, revision, projected_revision, last_pruned_at
            ) VALUES (?1, 0, 0, ?2)
            ON CONFLICT(provider) DO UPDATE SET last_pruned_at = excluded.last_pruned_at
            """
        )
        defer { sqlite3_finalize(mark) }
        try bind(provider, to: 1, in: mark)
        sqlite3_bind_double(mark, 2, now)
        try stepDone(mark, database: database, operation: "mark hook maintenance")
    }

    private func replaceHookLegacyFile(
        with data: Data,
        at stateURL: URL,
        fileManager: FileManager
    ) throws {
        let parentURL = stateURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: parentURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        try? fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: parentURL.path
        )
        let temporaryURL = parentURL.appendingPathComponent(
            ".\(stateURL.lastPathComponent).\(UUID().uuidString).tmp"
        )
        guard fileManager.createFile(
            atPath: temporaryURL.path,
            contents: data,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o600))]
        ) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: stateURL.path])
        }
        let renameResult = temporaryURL.path.withCString { source in
            stateURL.path.withCString { destination in
                Darwin.rename(source, destination)
            }
        }
        if renameResult != 0 {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            try? fileManager.removeItem(at: temporaryURL)
            throw POSIXError(code)
        }
        try? fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: stateURL.path
        )
    }

    private func verifiedHookLegacyPublication(
        at stateURL: URL,
        expectedJSON: Data
    ) throws -> LegacyStamp {
        let descriptor = open(stateURL.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.close(descriptor) }

        var openedStat = stat()
        guard fstat(descriptor, &openedStat) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard openedStat.st_size == off_t(expectedJSON.count) else {
            throw mutationConflictError()
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        var publishedJSON = Data()
        publishedJSON.reserveCapacity(expectedJSON.count)
        while publishedJSON.count <= expectedJSON.count {
            let readCount = min(
                64 * 1_024,
                expectedJSON.count + 1 - publishedJSON.count
            )
            guard readCount > 0,
                  let chunk = try handle.read(upToCount: readCount),
                  !chunk.isEmpty else {
                break
            }
            publishedJSON.append(chunk)
        }
        guard publishedJSON == expectedJSON else { throw mutationConflictError() }

        var pathStat = stat()
        guard lstat(stateURL.path, &pathStat) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard openedStat.st_dev == pathStat.st_dev,
              openedStat.st_ino == pathStat.st_ino else {
            throw mutationConflictError()
        }
        let modifiedAt = TimeInterval(openedStat.st_mtimespec.tv_sec)
            + TimeInterval(openedStat.st_mtimespec.tv_nsec) / 1_000_000_000
        return LegacyStamp(
            path: stateURL.path,
            size: Int64(openedStat.st_size),
            modifiedAt: modifiedAt
        )
    }

    /// Reads compatibility JSON from one descriptor with a strict allocation cap.
    /// The descriptor is checked before and during the read, so concurrent growth
    /// cannot make the caller allocate beyond `maximumBytes + 1`.
    public func readHookLegacySourceData(
        at url: URL,
        maximumBytes: Int64 = 64 * 1_024 * 1_024
    ) throws -> Data {
        let data = try readHookLegacySourceDataUnvalidated(at: url, maximumBytes: maximumBytes)
        _ = try scanHookLegacySourceData(data, path: url.path)
        return data
    }

    func readHookLegacySourceDataUnvalidated(
        at url: URL,
        maximumBytes: Int64
    ) throws -> Data {
        var pathMetadata = stat()
        guard stat(url.path, &pathMetadata) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard pathMetadata.st_mode & S_IFMT == S_IFREG else {
            throw POSIXError(.EFTYPE)
        }

        // O_NONBLOCK closes the race between the path check and open: if the
        // path is swapped for a FIFO, opening the descriptor still cannot hang.
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.close(descriptor) }

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard metadata.st_mode & S_IFMT == S_IFREG else {
            throw POSIXError(.EFTYPE)
        }
        guard metadata.st_size <= maximumBytes else {
            throw HookLegacySourceSizeError(
                path: url.path,
                observedBytes: Int64(metadata.st_size),
                maximumBytes: maximumBytes
            )
        }

        let maximumCount = Int(maximumBytes)
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        var data = Data()
        data.reserveCapacity(min(Int(metadata.st_size), maximumCount))
        while data.count <= maximumCount {
            let readCount = min(64 * 1_024, maximumCount + 1 - data.count)
            guard readCount > 0,
                  let chunk = try handle.read(upToCount: readCount),
                  !chunk.isEmpty else {
                break
            }
            data.append(chunk)
        }
        guard data.count <= maximumCount else {
            throw HookLegacySourceSizeError(
                path: url.path,
                observedBytes: Int64(data.count),
                maximumBytes: maximumBytes
            )
        }
        return data
    }
}
