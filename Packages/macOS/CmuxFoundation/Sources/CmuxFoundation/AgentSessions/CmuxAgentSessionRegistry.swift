public import Foundation
import Darwin
import SQLite3

/// Durable, cross-version storage for coding-agent sessions.
///
/// Persistence flow:
///
///     provider hook ──► one SQLite row per session/run owner
///          │                       │
///          │                       ├──► `cmux agents` (root + child tree)
///          │                       ├──► foreground / attention notification
///          │                       ├──► restore or fork (root authority only)
///          │                       └──► hibernation eligibility
///          │                              │
///          │                    active workload? ──yes──► stay awake
///          │                              │ no
///          │                              └──► snapshot + hibernate
///          │
///          ├── root TUI exits ──► end root run + cancel owned workloads
///          └──► legacy JSON (compatibility projection for older cmux)
///
/// Legacy JSON remains readable by older cmux releases, but it is never allowed
/// to replace a row written by a newer registry generation. This matters when a
/// stable, nightly, and tagged build run concurrently: an older Codable model
/// rewrites its complete JSON file and necessarily drops fields it cannot see.
/// SQLite makes the mutation boundary one session, while `writerGeneration`
/// makes schema ownership monotonic. A future schema change that adds persisted
/// semantics must increment `currentWriterGeneration`; older binaries can then
/// read the row but cannot encode their smaller model over it.
///
/// Every operation opens a short-lived connection with WAL and a bounded busy
/// timeout. Callers on the app side must use a utility task or queue. CLI hook
/// callers remain synchronous so the registry commit is durable before they
/// publish the compatibility JSON file.
public struct CmuxAgentSessionRegistry: Sendable {
    public static let currentWriterGeneration = 1
    public static let filename = "agent-sessions.sqlite3"
    /// Provider discovery feeds legacy sidecar paths, so identifiers are kept
    /// deliberately smaller and stricter than arbitrary SQLite text values.
    public static let maximumProviderIdentifierBytes = 128
    /// A hard ceiling prevents corrupt or adversarial metadata from amplifying
    /// one inspection command into an unbounded number of filesystem probes.
    public static let maximumProviderEnumerationCount = 256
    static let optimisticConflictCode = -7_867
    static let maximumMutationAttempts = 64

    public struct ProviderEnumerationLimitError: Error, Equatable, Sendable {
        public var maximumCount: Int
        public var observedAtLeast: Int

        public init(maximumCount: Int, observedAtLeast: Int) {
            self.maximumCount = maximumCount
            self.observedAtLeast = observedAtLeast
        }
    }

    public struct UnsafeProviderIdentifierError: Error, Equatable, Sendable {
        public var provider: String

        public init(provider: String) {
            self.provider = provider
        }
    }

    public enum Scope: String, Hashable, Sendable {
        case workspace
        case surface
    }

    public struct Record: Sendable {
        public var provider: String
        public var sessionID: String
        public var updatedAt: TimeInterval
        public var writerGeneration: Int
        public var json: Data

        public init(
            provider: String,
            sessionID: String,
            updatedAt: TimeInterval,
            writerGeneration: Int = CmuxAgentSessionRegistry.currentWriterGeneration,
            json: Data
        ) {
            self.provider = provider
            self.sessionID = sessionID
            self.updatedAt = updatedAt
            self.writerGeneration = writerGeneration
            self.json = json
        }
    }

    public struct ActiveSlot: Sendable {
        public var provider: String
        public var scope: Scope
        public var scopeID: String
        public var sessionID: String
        public var updatedAt: TimeInterval
        public var writerGeneration: Int
        public var json: Data

        public init(
            provider: String,
            scope: Scope,
            scopeID: String,
            sessionID: String,
            updatedAt: TimeInterval,
            writerGeneration: Int = CmuxAgentSessionRegistry.currentWriterGeneration,
            json: Data
        ) {
            self.provider = provider
            self.scope = scope
            self.scopeID = scopeID
            self.sessionID = sessionID
            self.updatedAt = updatedAt
            self.writerGeneration = writerGeneration
            self.json = json
        }
    }

    public struct ActiveSlotKey: Hashable, Sendable {
        public var scope: Scope
        public var scopeID: String

        public init(scope: Scope, scopeID: String) {
            self.scope = scope
            self.scopeID = scopeID
        }
    }

    public struct Snapshot: Sendable {
        public var records: [Record]
        public var activeSlots: [ActiveSlot]

        public init(records: [Record], activeSlots: [ActiveSlot]) {
            self.records = records
            self.activeSlots = activeSlots
        }
    }

    /// A recent provider slice plus the exact number of canonical session rows.
    /// Callers can merge one bounded slice per provider without retaining every
    /// encoded record merely to report a complete match count.
    public struct BoundedRecentSnapshot: Sendable {
        public var snapshot: Snapshot
        public var totalRecordCount: Int

        public init(snapshot: Snapshot, totalRecordCount: Int) {
            self.snapshot = snapshot
            self.totalRecordCount = totalRecordCount
        }
    }

    public enum ActiveSlotRemoval: Sendable {
        case all
        case updatedThrough(TimeInterval)
    }

    public enum RecordRebindResult: Equatable, Sendable {
        case patched
        case recordMissing
        case rejected
    }

    public struct LegacyStamp: Equatable, Sendable {
        public var path: String
        public var size: Int64
        public var modifiedAt: TimeInterval
        public var deviceID: Int64?
        public var inode: Int64?
        public var modifiedSeconds: Int64?
        public var modifiedNanoseconds: Int64?
        public var changedSeconds: Int64?
        public var changedNanoseconds: Int64?

        public init(
            path: String,
            size: Int64,
            modifiedAt: TimeInterval,
            deviceID: Int64? = nil,
            inode: Int64? = nil,
            modifiedSeconds: Int64? = nil,
            modifiedNanoseconds: Int64? = nil,
            changedSeconds: Int64? = nil,
            changedNanoseconds: Int64? = nil
        ) {
            self.path = path
            self.size = size
            self.modifiedAt = modifiedAt
            self.deviceID = deviceID
            self.inode = inode
            self.modifiedSeconds = modifiedSeconds
            self.modifiedNanoseconds = modifiedNanoseconds
            self.changedSeconds = changedSeconds
            self.changedNanoseconds = changedNanoseconds
        }

        init(path: String, metadata: stat) {
            let modifiedSeconds = Int64(metadata.st_mtimespec.tv_sec)
            let modifiedNanoseconds = Int64(metadata.st_mtimespec.tv_nsec)
            self.init(
                path: path,
                size: Int64(metadata.st_size),
                modifiedAt: TimeInterval(modifiedSeconds)
                    + TimeInterval(modifiedNanoseconds) / 1_000_000_000,
                deviceID: Int64(metadata.st_dev),
                inode: Int64(bitPattern: UInt64(metadata.st_ino)),
                modifiedSeconds: modifiedSeconds,
                modifiedNanoseconds: modifiedNanoseconds,
                changedSeconds: Int64(metadata.st_ctimespec.tv_sec),
                changedNanoseconds: Int64(metadata.st_ctimespec.tv_nsec)
            )
        }

        var hasDurableRevisionIdentity: Bool {
            deviceID != nil
                && inode != nil
                && modifiedSeconds != nil
                && modifiedNanoseconds != nil
                && changedSeconds != nil
                && changedNanoseconds != nil
        }

        public static func read(path: String, fileManager: FileManager = .default) -> LegacyStamp? {
            _ = fileManager
            var metadata = stat()
            guard stat(path, &metadata) == 0,
                  metadata.st_mode & S_IFMT == S_IFREG else {
                return nil
            }
            return LegacyStamp(path: path, metadata: metadata)
        }
    }

    public struct LegacySource: Sendable {
        public var provider: String
        public var url: URL

        public init(provider: String, url: URL) {
            self.provider = provider
            self.url = url
        }
    }

    public let url: URL
    public let busyTimeoutMilliseconds: Int32

    public init(url: URL, busyTimeoutMilliseconds: Int32 = 100) {
        self.url = url
        self.busyTimeoutMilliseconds = max(0, busyTimeoutMilliseconds)
    }

    public static func defaultURL(
        homeDirectory: String = NSHomeDirectory(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let explicit = normalized(environment["CMUX_AGENT_SESSION_REGISTRY_PATH"]) {
            return URL(fileURLWithPath: NSString(string: explicit).expandingTildeInPath)
        }
        let directory: URL
        if let stateDirectory = normalized(environment["CMUX_AGENT_HOOK_STATE_DIR"]) {
            directory = URL(
                fileURLWithPath: NSString(string: stateDirectory).expandingTildeInPath,
                isDirectory: true
            )
        } else {
            directory = URL(fileURLWithPath: homeDirectory, isDirectory: true)
                .appendingPathComponent(".cmuxterm", isDirectory: true)
        }
        return directory.appendingPathComponent(filename, isDirectory: false)
    }

    /// Returns the registry's distinct providers in primary-key order.
    ///
    /// The metadata table has one row per provider and a provider primary key.
    /// Reading at most one row beyond the effective limit keeps both SQLite work
    /// and retained memory bounded while still reporting overflow explicitly.
    public func providerIdentifiers(
        maximumCount requestedMaximumCount: Int = CmuxAgentSessionRegistry.maximumProviderEnumerationCount
    ) throws -> [String] {
        let maximumCount = min(
            max(0, requestedMaximumCount),
            Self.maximumProviderEnumerationCount
        )
        return try withDatabase { database in
            try readTransaction(database) {
                let statement = try prepare(
                    database,
                    """
                    SELECT provider FROM agent_provider_metadata
                    WHERE record_bytes > 0 OR slot_bytes > 0
                    ORDER BY provider
                    LIMIT ?1
                    """
                )
                defer { sqlite3_finalize(statement) }
                let bindResult = sqlite3_bind_int64(statement, 1, Int64(maximumCount + 1))
                guard bindResult == SQLITE_OK else {
                    throw bindingError(bindResult)
                }

                var providers: [String] = []
                providers.reserveCapacity(maximumCount)
                while try stepRow(
                    statement,
                    database: database,
                    operation: "enumerate agent session providers"
                ) {
                    guard let provider = text(statement, column: 0) else {
                        throw corruptRowError(operation: "enumerate agent session providers")
                    }
                    guard Self.isSafeProviderIdentifier(provider) else {
                        throw UnsafeProviderIdentifierError(provider: provider)
                    }
                    providers.append(provider)
                }
                guard providers.count <= maximumCount else {
                    throw ProviderEnumerationLimitError(
                        maximumCount: maximumCount,
                        observedAtLeast: maximumCount + 1
                    )
                }
                return providers
            }
        }
    }

    /// Performs one primary-key lookup for an exact, safe provider ID. This is
    /// intentionally independent of full enumeration so a targeted inspection
    /// still works when the registry contains more providers than the catalog
    /// is willing to probe at once.
    public func containsProviderIdentifier(_ provider: String) throws -> Bool {
        guard Self.isSafeProviderIdentifier(provider) else { return false }
        return try withDatabase { database in
            try readTransaction(database) {
                let statement = try prepare(
                    database,
                    """
                    SELECT 1 FROM agent_provider_metadata
                    WHERE provider = ?1 AND (record_bytes > 0 OR slot_bytes > 0)
                    LIMIT 1
                    """
                )
                defer { sqlite3_finalize(statement) }
                try bind(provider, to: 1, in: statement)
                return try stepRow(
                    statement,
                    database: database,
                    operation: "find agent session provider"
                )
            }
        }
    }

    /// Returns at most two active provider IDs that differ only by ASCII case.
    /// Two rows are enough for callers to reject a sidecar-path collision. The
    /// matching partial NOCASE index keeps this lookup independent of catalog
    /// size, including when full enumeration exceeds its hard ceiling.
    public func providerIdentifiers(caseInsensitiveTo provider: String) throws -> [String] {
        guard Self.isSafeProviderIdentifier(provider) else { return [] }
        return try withDatabase { database in
            try readTransaction(database) {
                let statement = try prepare(
                    database,
                    """
                    SELECT provider FROM agent_provider_metadata
                    WHERE provider = ?1 COLLATE NOCASE
                        AND (record_bytes > 0 OR slot_bytes > 0)
                    ORDER BY provider
                    LIMIT 2
                    """
                )
                defer { sqlite3_finalize(statement) }
                try bind(provider, to: 1, in: statement)
                var providers: [String] = []
                while try stepRow(
                    statement,
                    database: database,
                    operation: "find case-insensitive agent session providers"
                ) {
                    guard let provider = text(statement, column: 0),
                          Self.isSafeProviderIdentifier(provider) else {
                        throw corruptRowError(
                            operation: "find case-insensitive agent session providers"
                        )
                    }
                    providers.append(provider)
                }
                return providers
            }
        }
    }

    public static func isSafeProviderIdentifier(_ value: String) -> Bool {
        let bytes = value.utf8
        guard !bytes.isEmpty, bytes.count <= maximumProviderIdentifierBytes else {
            return false
        }
        return bytes.allSatisfy { byte in
            switch byte {
            case 48...57, 65...90, 97...122, 45, 46, 95:
                return true
            default:
                return false
            }
        }
    }

    public func snapshot(provider: String) throws -> Snapshot {
        try withDatabase { database in
            try readTransaction(database) {
                Snapshot(
                    records: try readRecords(database: database, provider: provider),
                    activeSlots: try readSlots(database: database, provider: provider)
                )
            }
        }
    }

    /// Reads selected session rows through one consistent, indexed snapshot.
    public func records(
        provider: String,
        sessionIDs: Set<String>
    ) throws -> [Record] {
        guard !sessionIDs.isEmpty else { return [] }
        return try withDatabase { database in
            try readTransaction(database) {
                try sessionIDs.compactMap {
                    try readRecord(database: database, provider: provider, sessionID: $0)
                }
            }
        }
    }

    /// Applies a provider snapshot mutation without holding the SQLite writer
    /// lock while the caller decodes or transforms records.
    ///
    /// The closure may be replayed after a touched row changes concurrently,
    /// so it must only derive its return value and mutations from the snapshot.
    /// Each commit validates the touched rows and applies their delta inside one
    /// short transaction. The busy timeout and attempt cap bound contention.
    public func mutateSnapshot<T>(
        provider: String,
        _ mutate: (inout Snapshot) throws -> T
    ) throws -> T {
        var lastContentionError: (any Error)?
        for _ in 0..<Self.maximumMutationAttempts {
            let previous: Snapshot
            do {
                previous = try snapshot(provider: provider)
            } catch {
                guard isRetryableMutationError(error) else { throw error }
                lastContentionError = error
                continue
            }
            var current = previous
            let result = try mutate(&current)
            do {
                try persistSnapshotChangesOptimistically(
                    provider: provider,
                    previous: previous,
                    current: current
                )
                return result
            } catch {
                guard isRetryableMutationError(error) else { throw error }
                lastContentionError = error
            }
        }
        throw lastContentionError ?? mutationConflictError()
    }

    public func snapshotImportingLegacy(
        provider: String,
        legacyURL: URL,
        fileManager: FileManager = .default
    ) throws -> Snapshot {
        let snapshots = try snapshotsImportingLegacy(
            sources: [LegacySource(provider: provider, url: legacyURL)],
            fileManager: fileManager
        )
        return snapshots[provider] ?? Snapshot(records: [], activeSlots: [])
    }

    typealias HookLegacySourceAdmissionLoader = (
        _ source: LegacySource,
        _ expectedStamp: LegacyStamp
    ) throws -> HookLegacySourceAdmission

    private enum RetryingHookLegacySourceAdmissionResult {
        case admitted(HookLegacySourceAdmission)
        case stableFailure(stamp: LegacyStamp, error: any Error)
        case unstable
    }

    /// Pins the compatibility bytes and stamp to one descriptor, retrying once
    /// when the path changes while it is being opened or read. A second change
    /// is reported as unstable instead of being mistaken for a malformed exact
    /// revision and quarantined under the wrong stamp.
    private func retryingHookLegacySourceAdmission(
        source: LegacySource,
        expectedStamp initialStamp: LegacyStamp,
        fileManager: FileManager,
        loader: HookLegacySourceAdmissionLoader
    ) -> RetryingHookLegacySourceAdmissionResult {
        var expectedStamp = initialStamp
        for attempt in 0..<2 {
            do {
                let admission = try loader(source, expectedStamp)
                guard admission.source.provider == source.provider,
                      admission.source.url.standardizedFileURL == source.url.standardizedFileURL,
                      admission.stamp == expectedStamp else {
                    throw HookLegacySourceRevisionChangedError(path: source.url.path)
                }
                return .admitted(admission)
            } catch {
                let observedStamp = LegacyStamp.read(
                    path: source.url.path,
                    fileManager: fileManager
                )
                let revisionChanged = error is HookLegacySourceRevisionChangedError
                    || observedStamp != Optional(expectedStamp)
                guard revisionChanged else {
                    return .stableFailure(stamp: expectedStamp, error: error)
                }
                guard attempt == 0, let observedStamp else { return .unstable }
                expectedStamp = observedStamp
            }
        }
        return .unstable
    }

    /// Public counterpart used by app restore preflight. The returned bytes and
    /// stamp always describe the same descriptor revision.
    public func hookLegacySourceAdmissionRetryingOneReplacement(
        source: LegacySource,
        expectedStamp: LegacyStamp,
        fileManager: FileManager = .default
    ) throws -> HookLegacySourceAdmission {
        switch retryingHookLegacySourceAdmission(
            source: source,
            expectedStamp: expectedStamp,
            fileManager: fileManager,
            loader: { source, stamp in
                try hookLegacySourceAdmission(
                    source: source,
                    expectedStamp: stamp,
                    fileManager: fileManager
                )
            }
        ) {
        case let .admitted(admission):
            return admission
        case let .stableFailure(_, error):
            throw error
        case .unstable:
            throw HookLegacySourceRevisionChangedError(path: source.url.path)
        }
    }

    /// Imports changed compatibility files without materializing provider
    /// snapshots. Session restore uses this bounded preflight before it adopts
    /// hibernated rows. A malformed provider is isolated from valid peers, while
    /// database failures still abort the preflight so callers can fail closed.
    public func refreshLegacySources(
        _ sources: [LegacySource],
        preservingCanonicalRestoreOwners restoreOwners: Set<RestoreOwnerContext> = [],
        fileManager: FileManager = .default
    ) throws -> LegacyRefreshResult {
        try refreshLegacySources(
            sources,
            preservingCanonicalRestoreOwners: restoreOwners,
            fileManager: fileManager,
            legacyAdmissionLoader: { source, stamp in
                try hookLegacySourceAdmission(
                    source: source,
                    expectedStamp: stamp,
                    fileManager: fileManager
                )
            }
        )
    }

    func refreshLegacySources(
        _ sources: [LegacySource],
        preservingCanonicalRestoreOwners restoreOwners: Set<RestoreOwnerContext> = [],
        fileManager: FileManager = .default,
        legacyAdmissionLoader: HookLegacySourceAdmissionLoader
    ) throws -> LegacyRefreshResult {
        let uniqueSources = Dictionary(
            sources.map { ($0.provider, $0) },
            uniquingKeysWith: { _, latest in latest }
        ).values.sorted { $0.provider < $1.provider }
        let restoreOwnersByProvider = Dictionary(
            grouping: restoreOwners,
            by: \.provider
        )
        return try withDatabase { database in
            var changed: [(source: LegacySource, stamp: LegacyStamp, payload: LegacyPayload)] = []
            var malformed: [(
                source: LegacySource,
                stamp: LegacyStamp,
                needsQuarantineWrite: Bool
            )] = []
            var failedProviders = Set<String>()
            var verifiedCanonicalRestoreOwners = Set<RestoreOwnerContext>()
            for source in uniqueSources {
                guard let stamp = LegacyStamp.read(path: source.url.path, fileManager: fileManager) else {
                    // SQLite is canonical after migration. A removed
                    // compatibility projection is harmless when this provider
                    // already has durable rows; first-time restore with neither
                    // source remains unavailable and is sanitized by the caller.
                    let providerRestoreOwners = Set(restoreOwnersByProvider[source.provider] ?? [])
                    if !providerRestoreOwners.isEmpty {
                        let verified = try verifyCanonicalRestoreOwners(
                            database: database,
                            provider: source.provider,
                            candidates: providerRestoreOwners
                        )
                        verifiedCanonicalRestoreOwners.formUnion(verified)
                        if verified.count != providerRestoreOwners.count {
                            failedProviders.insert(source.provider)
                        }
                    } else if try !hasRecord(database: database, provider: source.provider) {
                        failedProviders.insert(source.provider)
                    }
                    continue
                }
                let sourceState = try legacySourceState(
                    database: database,
                    provider: source.provider,
                    stamp: stamp
                )
                if sourceState == .imported { continue }
                if sourceState == .quarantined {
                    failedProviders.insert(source.provider)
                    malformed.append((source, stamp, false))
                    continue
                }
                switch retryingHookLegacySourceAdmission(
                    source: source,
                    expectedStamp: stamp,
                    fileManager: fileManager,
                    loader: legacyAdmissionLoader
                ) {
                case let .admitted(admission):
                    let admittedState = try legacySourceState(
                        database: database,
                        provider: source.provider,
                        stamp: admission.stamp
                    )
                    if admittedState == .imported { continue }
                    if admittedState == .quarantined {
                        failedProviders.insert(source.provider)
                        malformed.append((source, admission.stamp, false))
                        continue
                    }
                    do {
                        changed.append((
                            source,
                            admission.stamp,
                            try legacyPayload(provider: source.provider, json: admission.json)
                        ))
                    } catch {
                        failedProviders.insert(source.provider)
                        malformed.append((source, admission.stamp, true))
                    }
                case let .stableFailure(failedStamp, _):
                    failedProviders.insert(source.provider)
                    malformed.append((source, failedStamp, true))
                case .unstable:
                    failedProviders.insert(source.provider)
                    malformed.append((source, stamp, false))
                }
            }
            func verifyMalformedOwners(
                _ items: [(source: LegacySource, stamp: LegacyStamp, needsQuarantineWrite: Bool)]
            ) throws {
                for item in items {
                    let candidates = Set(restoreOwnersByProvider[item.source.provider] ?? [])
                    guard !candidates.isEmpty else { continue }
                    let verified = try verifyCanonicalRestoreOwners(
                        database: database,
                        provider: item.source.provider,
                        candidates: candidates
                    )
                    guard !verified.isEmpty else { continue }
                    verifiedCanonicalRestoreOwners.formUnion(verified)
                    guard item.needsQuarantineWrite else { continue }
                    // Quarantine only this malformed revision. Restore can now
                    // adopt the independently verified canonical rows; any
                    // later compatibility rewrite has a different stamp and is
                    // imported normally on the next refresh.
                    try writeLegacyStamp(
                        database: database,
                        provider: item.source.provider,
                        stamp: item.stamp,
                        quarantined: true
                    )
                }
            }
            let needsWriteTransaction = !changed.isEmpty || malformed.contains {
                $0.needsQuarantineWrite
            }
            if needsWriteTransaction {
                // This API is used synchronously immediately before panel
                // restore. One busy timeout is its complete lock-wait budget.
                try transaction(database, retryBeginContention: false) {
                    for item in changed {
                        try replaceLegacy(
                            database: database,
                            provider: item.source.provider,
                            stamp: item.stamp,
                            payload: item.payload
                        )
                    }
                    try verifyMalformedOwners(malformed)
                }
            } else if !malformed.isEmpty {
                try readTransaction(database) {
                    try verifyMalformedOwners(malformed)
                }
            }
            return LegacyRefreshResult(
                refreshedProviders: Set(changed.map { $0.source.provider }),
                failedProviders: failedProviders,
                verifiedCanonicalRestoreOwners: verifiedCanonicalRestoreOwners
            )
        }
    }

    /// Verifies only the requested session row and its singular surface lease.
    /// Both reads use primary keys, so corrupt-sidecar recovery scales with the
    /// bounded restore snapshot instead of provider history.
    private func verifyCanonicalRestoreOwners(
        database: OpaquePointer,
        provider: String,
        candidates: Set<RestoreOwnerContext>
    ) throws -> Set<RestoreOwnerContext> {
        var verified = Set<RestoreOwnerContext>()
        verified.reserveCapacity(candidates.count)
        for candidate in candidates where candidate.provider == provider {
            guard let record = try readRecord(
                database: database,
                provider: provider,
                sessionID: candidate.sessionID
            ),
            record.writerGeneration >= Self.currentWriterGeneration,
            let surfaceSlot = try readSlot(
                database: database,
                provider: provider,
                scope: .surface,
                scopeID: candidate.surfaceID
            ),
            surfaceSlot.writerGeneration >= Self.currentWriterGeneration,
            surfaceSlot.sessionID == candidate.sessionID,
            let recordObject = try? JSONSerialization.jsonObject(with: record.json) as? [String: Any],
            recordObject["sessionId"] as? String == candidate.sessionID,
            identifiersEqual(recordObject["workspaceId"] as? String, candidate.workspaceID),
            identifiersEqual(recordObject["surfaceId"] as? String, candidate.surfaceID),
            recordObject["sessionState"] as? String == "hibernated",
            CmuxAgentSessionRunAuthorityProjection()
                .projectedRestoreAuthority(recordJSON: record.json) == true,
            recordObject["updatedAt"] is TimeInterval,
            !hasCompletion(recordObject),
            let slotObject = try? JSONSerialization.jsonObject(with: surfaceSlot.json) as? [String: Any],
            slotObject["sessionId"] as? String == candidate.sessionID,
            slotObject["updatedAt"] is TimeInterval else {
                continue
            }
            verified.insert(candidate)
        }
        return verified
    }

    private func identifiersEqual(_ value: String?, _ expected: String) -> Bool {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return false }
        return value.caseInsensitiveCompare(expected) == .orderedSame
    }

    private func hasCompletion(_ record: [String: Any]) -> Bool {
        guard let completedAt = record["completedAt"] else { return false }
        return !(completedAt is NSNull)
    }

    /// Refreshes all changed compatibility files and reads every requested
    /// provider through one SQLite connection. This is the tree/restore path,
    /// so its cost does not grow by one connection per supported adapter.
    public func snapshotsImportingLegacy(
        sources: [LegacySource],
        fileManager: FileManager = .default
    ) throws -> [String: Snapshot] {
        let uniqueSources = Dictionary(
            sources.map { ($0.provider, $0) },
            uniquingKeysWith: { _, latest in latest }
        ).values.sorted { $0.provider < $1.provider }
        return try withDatabase { database in
            var changed: [(source: LegacySource, stamp: LegacyStamp, payload: LegacyPayload)] = []
            for source in uniqueSources {
                guard let stamp = LegacyStamp.read(path: source.url.path, fileManager: fileManager),
                      try !legacySourceIsCurrent(
                        database: database,
                        provider: source.provider,
                        stamp: stamp
                      ) else { continue }
                let admission = try hookLegacySourceAdmissionRetryingOneReplacement(
                    source: source,
                    expectedStamp: stamp,
                    fileManager: fileManager
                )
                guard try !legacySourceIsCurrent(
                    database: database,
                    provider: source.provider,
                    stamp: admission.stamp
                ) else { continue }
                changed.append((
                    source,
                    admission.stamp,
                    try legacyPayload(provider: source.provider, json: admission.json)
                ))
            }
            if !changed.isEmpty {
                try transaction(database) {
                    for item in changed {
                        try replaceLegacy(
                            database: database,
                            provider: item.source.provider,
                            stamp: item.stamp,
                            payload: item.payload
                        )
                    }
                }
            }
            return try readTransaction(database) {
                try Dictionary(uniqueKeysWithValues: uniqueSources.map { source in
                    (source.provider, Snapshot(
                        records: try readRecords(database: database, provider: source.provider),
                        activeSlots: try readSlots(database: database, provider: source.provider)
                    ))
                })
            }
        }
    }

    /// Refreshes changed compatibility sources, then reads only each provider's
    /// newest list candidates and the active slots that annotate those rows.
    /// All providers share one SQLite connection and one read transaction.
    public func boundedRecentSnapshotsImportingLegacy(
        sources: [LegacySource],
        maximumRecordsPerProvider: Int,
        fileManager: FileManager = .default,
        validateRecord: ((String, Record) throws -> Void)? = nil,
        validateActiveSlot: ((String, ActiveSlot) throws -> Void)? = nil
    ) throws -> [String: BoundedRecentSnapshot] {
        let uniqueSources = Dictionary(
            sources.map { ($0.provider, $0) },
            uniquingKeysWith: { _, latest in latest }
        ).values.sorted { $0.provider < $1.provider }
        let maximumRecordsPerProvider = max(0, maximumRecordsPerProvider)
        return try withDatabase { database in
            var changed: [(source: LegacySource, stamp: LegacyStamp, payload: LegacyPayload)] = []
            for source in uniqueSources {
                guard let stamp = LegacyStamp.read(path: source.url.path, fileManager: fileManager),
                      try !legacySourceIsCurrent(
                        database: database,
                        provider: source.provider,
                        stamp: stamp
                      ) else { continue }
                do {
                    let admission = try hookLegacySourceAdmissionRetryingOneReplacement(
                        source: source,
                        expectedStamp: stamp,
                        fileManager: fileManager
                    )
                    guard try !legacySourceIsCurrent(
                        database: database,
                        provider: source.provider,
                        stamp: admission.stamp
                    ) else { continue }
                    changed.append((
                        source,
                        admission.stamp,
                        try legacyPayload(provider: source.provider, json: admission.json)
                    ))
                } catch {
                    throw HookLegacySourceImportError(provider: source.provider)
                }
            }
            if !changed.isEmpty {
                try transaction(database) {
                    for item in changed {
                        try replaceLegacy(
                            database: database,
                            provider: item.source.provider,
                            stamp: item.stamp,
                            payload: item.payload
                        )
                    }
                }
            }
            return try readTransaction(database) {
                try Dictionary(uniqueKeysWithValues: uniqueSources.map { source in
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
                    return (source.provider, BoundedRecentSnapshot(
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
                    ))
                })
            }
        }
    }

    public func legacySourceIsCurrent(provider: String, stamp: LegacyStamp) throws -> Bool {
        try withDatabase { database in
            try legacySourceIsCurrent(database: database, provider: provider, stamp: stamp)
        }
    }

    /// Returns whether an exact compatibility revision has already been
    /// imported or quarantined after canonical restore-owner verification.
    /// Canonical rebinds may skip either state; projection readers still use
    /// `legacySourceIsCurrent` so a quarantined sidecar is repaired normally.
    public func canonicalRebindCanSkipLegacySource(
        provider: String,
        stamp: LegacyStamp
    ) throws -> Bool {
        try withDatabase { database in
            try legacySourceCanBeSkippedForCanonicalRebind(
                database: database,
                provider: provider,
                stamp: stamp
            )
        }
    }

    /// Imports a complete compatibility snapshot. Generation-zero rows may
    /// replace only other generation-zero rows. Current or future rows win.
    public func importLegacy(
        provider: String,
        stamp: LegacyStamp,
        records: [Record],
        activeSlots: [ActiveSlot]
    ) throws {
        try withDatabase { database in
            try transaction(database) {
                try replaceLegacy(
                    database: database,
                    provider: provider,
                    stamp: stamp,
                    payload: LegacyPayload(records: records, activeSlots: activeSlots)
                )
            }
        }
    }

    /// Imports the raw compatibility store without decoding it through the
    /// caller's model. This preserves keys introduced by another cmux version.
    public func importLegacyStoreJSON(
        provider: String,
        stamp: LegacyStamp,
        json: Data
    ) throws {
        let payload = try legacyPayload(provider: provider, json: json)
        try importLegacy(
            provider: provider,
            stamp: stamp,
            records: payload.records,
            activeSlots: payload.activeSlots
        )
    }

    struct LegacyPayload {
        var records: [Record]
        var activeSlots: [ActiveSlot]
    }

    func legacyPayload(provider: String, json: Data) throws -> LegacyPayload {
        guard let root = try JSONSerialization.jsonObject(with: json) as? [String: Any],
              let sessions = root["sessions"] as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var records: [Record] = []
        records.reserveCapacity(sessions.count)
        for (sessionID, value) in sessions {
            guard let object = value as? [String: Any],
                  let embeddedSessionID = object["sessionId"] as? String,
                  embeddedSessionID == sessionID,
                  JSONSerialization.isValidJSONObject(object),
                  let updatedAt = object["updatedAt"] as? TimeInterval,
                  let recordJSON = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            records.append(Record(
                provider: provider,
                sessionID: sessionID,
                updatedAt: updatedAt,
                writerGeneration: 0,
                json: recordJSON
            ))
        }
        var activeSlots: [ActiveSlot] = []
        for (key, scope) in [
            ("activeSessionsByWorkspace", Scope.workspace),
            ("activeSessionsBySurface", Scope.surface),
        ] {
            let slots: [String: Any]
            if let value = root[key] {
                guard let decoded = value as? [String: Any] else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                slots = decoded
            } else {
                slots = [:]
            }
            for (scopeID, value) in slots {
                guard let object = value as? [String: Any],
                      let sessionID = object["sessionId"] as? String,
                      let updatedAt = object["updatedAt"] as? TimeInterval,
                      JSONSerialization.isValidJSONObject(object),
                      let recordJSON = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                activeSlots.append(ActiveSlot(
                    provider: provider,
                    scope: scope,
                    scopeID: scopeID,
                    sessionID: sessionID,
                    updatedAt: updatedAt,
                    writerGeneration: 0,
                    json: recordJSON
                ))
            }
        }
        return LegacyPayload(records: records, activeSlots: activeSlots)
    }

    /// Applies only rows changed by the current hook event. The SQL conflict
    /// clause rejects attempts to replace a row owned by a newer generation.
    public func apply(
        provider: String,
        records: [Record],
        deletedSessionIDs: Set<String> = [],
        activeSlots: [ActiveSlot] = [],
        deletedSlots: Set<String> = []
    ) throws {
        try validateHookWriteBatch(
            provider: provider,
            records: records,
            activeSlots: activeSlots
        )
        try withDatabase { database in
            try transaction(database) {
                let previousProviderBytes = try hookProviderStorageBytes(
                    database: database,
                    provider: provider
                )
                for var record in records {
                    record.provider = provider
                    try upsert(record, database: database)
                }
                for sessionID in deletedSessionIDs {
                    try deleteSession(
                        database: database,
                        provider: provider,
                        sessionID: sessionID,
                        maximumWriterGeneration: Self.currentWriterGeneration
                    )
                }
                for var slot in activeSlots {
                    slot.provider = provider
                    try upsert(slot, database: database)
                }
                for compoundKey in deletedSlots {
                    let components = compoundKey.split(separator: "\u{0}", maxSplits: 1).map(String.init)
                    guard components.count == 2, let scope = Scope(rawValue: components[0]) else { continue }
                    try deleteSlot(
                        database: database,
                        provider: provider,
                        scope: scope,
                        scopeID: components[1],
                        maximumWriterGeneration: Self.currentWriterGeneration
                    )
                }
                try reconcileHookProviderStorageLimit(
                    database: database,
                    provider: provider,
                    protectedSessionIDs: Set(records.map(\.sessionID)),
                    previousBytes: previousProviderBytes
                )
            }
        }
    }

    public func markLegacySource(provider: String, stamp: LegacyStamp) throws {
        try withDatabase { database in
            try writeLegacyStamp(database: database, provider: provider, stamp: stamp)
        }
    }

    /// Patches a single registry row without decoding it into the caller's
    /// older Codable type. Unknown keys and a newer writer generation survive.
    public func patchRecord(
        provider: String,
        sessionID: String,
        updatedAt: TimeInterval,
        activeSlotRemoval: ActiveSlotRemoval? = nil,
        shouldMutate: ([String: Any]) -> Bool = { _ in true },
        mutate: (inout [String: Any]) -> Void
    ) throws -> Bool {
        try withDatabase { database in
            try transaction(database) {
                let previousProviderBytes = try hookProviderStorageBytes(
                    database: database,
                    provider: provider
                )
                guard let existing = try readRecord(
                    database: database,
                    provider: provider,
                    sessionID: sessionID
                ),
                var object = try JSONSerialization.jsonObject(with: existing.json) as? [String: Any] else {
                    return false
                }
                guard shouldMutate(object) else { return false }
                mutate(&object)
                guard JSONSerialization.isValidJSONObject(object) else { return false }
                let json = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
                try upsert(
                    Record(
                        provider: provider,
                        sessionID: sessionID,
                        updatedAt: updatedAt,
                        writerGeneration: max(existing.writerGeneration, Self.currentWriterGeneration),
                        json: json
                    ),
                    database: database
                )
                if let activeSlotRemoval {
                    try removeActiveSlots(
                        database: database,
                        provider: provider,
                        sessionID: sessionID,
                        removal: activeSlotRemoval,
                        maximumWriterGeneration: Self.currentWriterGeneration
                    )
                }
                try reconcileHookProviderStorageLimit(
                    database: database,
                    provider: provider,
                    protectedSessionIDs: [sessionID],
                    previousBytes: previousProviderBytes
                )
                return true
            }
        }
    }

    /// Patches one session row and moves its known active slots in one
    /// transaction. Every lookup is backed by a primary key, so restore cost
    /// does not grow with the number of sessions owned by the provider.
    ///
    /// A destination owned by another session rejects the complete mutation.
    /// Callers can also require every destination to exist already, turning the
    /// operation into an ownership claim rather than a slot creation.
    /// A previous slot that has already changed owners is left untouched. Slot
    /// JSON merges the owned sources from oldest to newest so unknown keys and
    /// a newer writer generation survive the move.
    public func patchRecordRebindingActiveSlots(
        provider: String,
        sessionID: String,
        updatedAt: TimeInterval,
        previousSlots: [ActiveSlotKey],
        activeSlots: [ActiveSlotKey],
        requireExistingActiveSlots: Bool = false,
        monotonicUpdatedAt: Bool = false,
        shouldMutate: ([String: Any]) -> Bool = { _ in true },
        mutate: (inout [String: Any]) -> Void
    ) throws -> RecordRebindResult {
        return try withDatabase { database in
            // Session restore runs on the main actor. One SQLite busy timeout
            // is the complete lock-wait budget; the caller may retry off-main.
            try transaction(database, retryBeginContention: false) {
                try patchRecordRebindingActiveSlots(
                    database: database,
                    provider: provider,
                    sessionID: sessionID,
                    updatedAt: updatedAt,
                    previousSlots: previousSlots,
                    activeSlots: activeSlots,
                    requireExistingActiveSlots: requireExistingActiveSlots,
                    monotonicUpdatedAt: monotonicUpdatedAt,
                    shouldMutate: shouldMutate,
                    mutate: mutate
                )
            }
        }
    }

    /// Refreshes one compatibility source and adopts its hibernated row through
    /// one SQLite connection and one writer transaction. Restore callers hold
    /// the provider sidecar's shared lock across this call, preventing an older
    /// JSON writer from changing the source between import and rebind.
    public func refreshLegacySourceAndPatchRecordRebindingActiveSlots(
        provider: String,
        legacyURL: URL,
        fileManager: FileManager = .default,
        sessionID: String,
        updatedAt: TimeInterval,
        previousSlots: [ActiveSlotKey],
        activeSlots: [ActiveSlotKey],
        requireExistingActiveSlots: Bool = false,
        monotonicUpdatedAt: Bool = false,
        shouldMutate: ([String: Any]) -> Bool = { _ in true },
        mutate: (inout [String: Any]) -> Void
    ) throws -> RecordRebindResult {
        try withLegacySourceRebindBatch(provider: provider, legacyURL: legacyURL, fileManager: fileManager) { batch in
            try batch.patchRecordRebindingActiveSlots(
                provider: provider,
                sessionID: sessionID,
                updatedAt: updatedAt,
                previousSlots: previousSlots,
                activeSlots: activeSlots,
                requireExistingActiveSlots: requireExistingActiveSlots,
                monotonicUpdatedAt: monotonicUpdatedAt,
                shouldMutate: shouldMutate,
                mutate: mutate
            )
        }
    }

    /// Performs indexed record/slot mutations through one SQLite connection
    /// and one writer transaction. The complete batch consumes at most one
    /// busy-timeout budget, independent of its record count.
    public func withRecordRebindBatch<T>(
        _ body: (RecordRebindBatch) throws -> T
    ) throws -> T {
        try withDatabase { database in
            try transaction(database, retryBeginContention: false) {
                let batch = RecordRebindBatch(registry: self, database: database)
                defer { batch.invalidate() }
                return try body(batch)
            }
        }
    }

    /// Imports one provider and performs every requested indexed rebind in one
    /// writer transaction. Lock contention consumes one busy timeout for the
    /// complete batch, independent of the number of restored panels.
    public func withLegacySourceRebindBatch<T>(
        provider: String,
        legacyURL: URL,
        fileManager: FileManager = .default,
        _ body: (RecordRebindBatch) throws -> T
    ) throws -> T {
        return try withDatabase { database in
            let changedLegacy: (stamp: LegacyStamp, payload: LegacyPayload)?
            if let stamp = LegacyStamp.read(path: legacyURL.path, fileManager: fileManager),
               try !legacySourceCanBeSkippedForCanonicalRebind(
                   database: database,
                   provider: provider,
                   stamp: stamp
               ) {
                let source = LegacySource(provider: provider, url: legacyURL)
                let admission = try hookLegacySourceAdmissionRetryingOneReplacement(
                    source: source,
                    expectedStamp: stamp,
                    fileManager: fileManager
                )
                if try legacySourceCanBeSkippedForCanonicalRebind(
                    database: database,
                    provider: provider,
                    stamp: admission.stamp
                ) {
                    changedLegacy = nil
                } else {
                    changedLegacy = (
                        admission.stamp,
                        try legacyPayload(provider: provider, json: admission.json)
                    )
                }
            } else {
                changedLegacy = nil
            }
            // Import and ownership transfer are indivisible. A concurrent
            // registry writer either precedes the complete restore mutation or
            // observes it after commit.
            return try transaction(database, retryBeginContention: false) {
                if let changedLegacy {
                    try replaceLegacy(
                        database: database,
                        provider: provider,
                        stamp: changedLegacy.stamp,
                        payload: changedLegacy.payload
                    )
                }
                let batch = RecordRebindBatch(registry: self, database: database)
                defer { batch.invalidate() }
                return try body(batch)
            }
        }
    }

    func patchRecordRebindingActiveSlots(
        database: OpaquePointer,
        provider: String,
        sessionID: String,
        updatedAt: TimeInterval,
        previousSlots: [ActiveSlotKey],
        activeSlots: [ActiveSlotKey],
        requireExistingActiveSlots: Bool,
        monotonicUpdatedAt: Bool,
        shouldMutate: ([String: Any]) -> Bool,
        mutate: (inout [String: Any]) -> Void
    ) throws -> RecordRebindResult {
        let previousProviderBytes = try hookProviderStorageBytes(
            database: database,
            provider: provider
        )
        let previousKeys = Set(previousSlots)
        let activeKeys = Set(activeSlots)
        let keys = previousKeys.union(activeKeys)
        guard let existingRecord = try readRecord(
            database: database,
            provider: provider,
            sessionID: sessionID
        ) else {
            return .recordMissing
        }
        guard let decodedRecord = try? JSONSerialization.jsonObject(with: existingRecord.json),
              var object = decodedRecord as? [String: Any] else {
            return .rejected
        }
        guard shouldMutate(object) else { return .rejected }

        var storedSlots: [ActiveSlotKey: ActiveSlot] = [:]
        storedSlots.reserveCapacity(keys.count)
        for key in keys {
            if let slot = try readSlot(
                database: database,
                provider: provider,
                scope: key.scope,
                scopeID: key.scopeID
            ) {
                storedSlots[key] = slot
            }
        }
        guard activeKeys.allSatisfy({ key in
            guard let slot = storedSlots[key] else {
                return !requireExistingActiveSlots
            }
            return slot.sessionID == sessionID
        }) else {
            return .rejected
        }
        let ownedSlots = storedSlots.values
            .filter { $0.sessionID == sessionID }
            .sorted {
                if $0.updatedAt != $1.updatedAt { return $0.updatedAt < $1.updatedAt }
                if $0.scope.rawValue != $1.scope.rawValue {
                    return $0.scope.rawValue < $1.scope.rawValue
                }
                return $0.scopeID < $1.scopeID
            }
        var effectiveUpdatedAt = monotonicUpdatedAt
            ? max(
                updatedAt,
                existingRecord.updatedAt,
                ownedSlots.map(\.updatedAt).max() ?? -.infinity
            )
            : updatedAt
        var slotObject: [String: Any] = [:]
        for ownedSlot in ownedSlots {
            guard let decodedJSON = try? JSONSerialization.jsonObject(with: ownedSlot.json),
                  let decoded = decodedJSON as? [String: Any] else {
                return .rejected
            }
            slotObject.merge(decoded) { _, new in new }
        }
        slotObject["sessionId"] = sessionID
        let slotWriterGeneration = max(
            Self.currentWriterGeneration,
            ownedSlots.map(\.writerGeneration).max() ?? 0
        )

        mutate(&object)
        if monotonicUpdatedAt {
            effectiveUpdatedAt = max(
                effectiveUpdatedAt,
                object["updatedAt"] as? TimeInterval ?? -.infinity
            )
            object["updatedAt"] = effectiveUpdatedAt
        }
        slotObject["updatedAt"] = effectiveUpdatedAt
        guard JSONSerialization.isValidJSONObject(slotObject),
              let slotJSON = try? JSONSerialization.data(
                  withJSONObject: slotObject,
                  options: [.sortedKeys]
              ) else {
            return .rejected
        }
        guard JSONSerialization.isValidJSONObject(object),
              let recordJSON = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys]
              ) else { return .rejected }
        try upsert(
            Record(
                provider: provider,
                sessionID: sessionID,
                updatedAt: effectiveUpdatedAt,
                writerGeneration: max(
                    existingRecord.writerGeneration,
                    Self.currentWriterGeneration
                ),
                json: recordJSON
            ),
            database: database
        )

        for key in previousKeys.subtracting(activeKeys) {
            guard let storedSlot = storedSlots[key],
                  storedSlot.sessionID == sessionID else { continue }
            try deleteSlot(
                database: database,
                provider: provider,
                scope: key.scope,
                scopeID: key.scopeID,
                maximumWriterGeneration: max(
                    storedSlot.writerGeneration,
                    Self.currentWriterGeneration
                )
            )
        }

        for key in activeKeys {
            try upsert(
                ActiveSlot(
                    provider: provider,
                    scope: key.scope,
                    scopeID: key.scopeID,
                    sessionID: sessionID,
                    updatedAt: effectiveUpdatedAt,
                    writerGeneration: slotWriterGeneration,
                    json: slotJSON
                ),
                database: database
            )
        }
        try reconcileHookProviderStorageLimit(
            database: database,
            provider: provider,
            protectedSessionIDs: [sessionID],
            previousBytes: previousProviderBytes
        )
        return .patched
    }

    public static func slotKey(scope: Scope, scopeID: String) -> String {
        "\(scope.rawValue)\u{0}\(scopeID)"
    }

}
