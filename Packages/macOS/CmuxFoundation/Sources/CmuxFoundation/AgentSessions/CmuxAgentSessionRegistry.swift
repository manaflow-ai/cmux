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
    static let optimisticConflictCode = -7_867
    static let maximumMutationAttempts = 64

    public enum Scope: String, Sendable {
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

    public struct Snapshot: Sendable {
        public var records: [Record]
        public var activeSlots: [ActiveSlot]

        public init(records: [Record], activeSlots: [ActiveSlot]) {
            self.records = records
            self.activeSlots = activeSlots
        }
    }

    public enum ActiveSlotRemoval: Sendable {
        case all
        case updatedThrough(TimeInterval)
    }

    public struct LegacyStamp: Equatable, Sendable {
        public var path: String
        public var size: Int64
        public var modifiedAt: TimeInterval

        public init(path: String, size: Int64, modifiedAt: TimeInterval) {
            self.path = path
            self.size = size
            self.modifiedAt = modifiedAt
        }

        public static func read(path: String, fileManager: FileManager = .default) -> LegacyStamp? {
            guard let attributes = try? fileManager.attributesOfItem(atPath: path),
                  let size = (attributes[.size] as? NSNumber)?.int64Value,
                  let modifiedAt = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 else {
                return nil
            }
            return LegacyStamp(path: path, size: size, modifiedAt: modifiedAt)
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
                let data = try Data(contentsOf: source.url)
                changed.append((source, stamp, try legacyPayload(provider: source.provider, json: data)))
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

    public func legacySourceIsCurrent(provider: String, stamp: LegacyStamp) throws -> Bool {
        try withDatabase { database in
            try legacySourceIsCurrent(database: database, provider: provider, stamp: stamp)
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

    private func legacyPayload(provider: String, json: Data) throws -> LegacyPayload {
        guard let root = try JSONSerialization.jsonObject(with: json) as? [String: Any],
              let sessions = root["sessions"] as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var records: [Record] = []
        records.reserveCapacity(sessions.count)
        for (sessionID, value) in sessions {
            guard let object = value as? [String: Any],
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
        try withDatabase { database in
            try transaction(database) {
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
                return true
            }
        }
    }

    public static func slotKey(scope: Scope, scopeID: String) -> String {
        "\(scope.rawValue)\u{0}\(scopeID)"
    }

}
