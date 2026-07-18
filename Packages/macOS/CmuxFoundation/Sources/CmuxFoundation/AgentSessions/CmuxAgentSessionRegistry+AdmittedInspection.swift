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
