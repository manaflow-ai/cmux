public import CMUXMobileCore
public import Foundation
import SQLite3
import os

let pairedMacStoreLog = Logger(subsystem: "com.cmuxterm.app", category: "PairedMacStore")

/// SQLite-backed store of paired Macs. Schema migrations gated on
/// `PRAGMA user_version`.
///
/// An `actor` serializes all access to the (non-`Sendable`, not-thread-safe)
/// SQLite connection, so it is genuinely `Sendable` without opting out of
/// concurrency checking. Construct it once at the app composition root and
/// inject it as `any MobilePairedMacStoring`.
public actor MobilePairedMacStore: MobilePairedMacPairingStoring {
    /// The schema version this build creates and migrates to.
    public static let currentSchemaVersion: Int32 = 12

    /// Keep route-removal suppression bounded. Once a scope churns beyond this
    /// limit, it parks a conservative kind-wide marker until explicit pairing.
    static let routeRemovalTombstoneLimit: Int32 = 256
    static let routeRemovalWildcardEndpoint = "*"

    private let dbPath: String
    let importingLegacyDatabaseURL: URL?
    // `nonisolated(unsafe)` only so the (Swift 6 nonisolated) `deinit` can close
    // the handle. Every other access goes through actor-isolated methods, and
    // the connection itself is opened `SQLITE_OPEN_FULLMUTEX`, so this is safe.
    nonisolated(unsafe) var db: OpaquePointer?

    /// The default on-disk location for the paired-Mac database.
    /// - Parameter fileManager: File manager used to resolve and create the directory.
    /// - Returns: The `paired-macs.sqlite3` URL under Application Support/cmux.
    /// - Throws: Any error thrown while resolving or creating the directory.
    public static func defaultDatabaseURL(fileManager: FileManager = .default) throws -> URL {
        let appSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = appSupport.appendingPathComponent("cmux", isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir.appendingPathComponent("paired-macs.sqlite3")
    }

    /// Open (creating if needed) the store at the given database URL.
    /// - Parameters:
    ///   - databaseURL: On-disk SQLite file location.
    ///   - importingLegacyDatabaseURL: Optional same-installation saved-Mac database
    ///     to import once. Callers must establish that both files belong to the
    ///     same backend environment. The source stays unchanged.
    /// - Throws: ``MobilePairedMacStoreError`` if the connection cannot be opened.
    public init(databaseURL: URL, importingLegacyDatabaseURL: URL? = nil) throws {
        self.dbPath = databaseURL.path
        self.importingLegacyDatabaseURL = importingLegacyDatabaseURL
        self.db = try Self.openConnection(path: databaseURL.path)
    }

    /// Open the store at ``defaultDatabaseURL(fileManager:)``.
    /// - Throws: ``MobilePairedMacStoreError`` if the connection cannot be opened.
    public init() throws {
        try self.init(databaseURL: Self.defaultDatabaseURL())
    }

    deinit {
        if let db {
            sqlite3_close_v2(db)
        }
    }

    var didMigrate = false

    // MARK: - Public API

    /// Load every paired Mac visible to the optional Stack user and team scope.
    public func loadAll(stackUserID: String? = nil, teamID: String? = nil) throws -> [MobilePairedMac] {
        try ensureReady()
        return try fetchAllMacs(stackUserID: stackUserID, teamID: teamID)
    }

    /// Load the active paired Mac in the optional Stack user and team scope.
    public func activeMac(stackUserID: String? = nil, teamID: String? = nil) throws -> MobilePairedMac? {
        try ensureReady()
        return try fetchAllMacs(activeOnly: true, stackUserID: stackUserID, teamID: teamID).first
    }

    /// Mark one paired Mac active within its explicit account/team owner scope.
    public func setActive(
        macDeviceID: String,
        stackUserID: String? = nil,
        teamID: String? = nil
    ) throws {
        try ensureReady()
        let macDeviceID = cmxCanonicalDeviceID(macDeviceID)
        let matches = try fetchAllMacs(
            stackUserID: stackUserID,
            teamID: teamID
        ).filter { $0.macDeviceID == macDeviceID }
        guard matches.count == 1, let target = matches.first else { return }
        try setActive(
            macDeviceID: macDeviceID,
            instanceTag: target.instanceTag,
            stackUserID: stackUserID,
            teamID: teamID
        )
    }

    /// Mark one tagged paired Mac active within its account/team owner scope.
    public func setActive(
        macDeviceID: String,
        instanceTag: String?,
        stackUserID: String? = nil,
        teamID: String? = nil
    ) throws {
        try ensureReady()
        let macDeviceID = cmxCanonicalDeviceID(macDeviceID)
        let ownerKey = Self.ownerKey(
            stackUserID: stackUserID,
            teamID: teamID,
            instanceTag: instanceTag
        )
        try transaction {
            try clearActiveMacs(stackUserID: stackUserID, teamID: teamID)
            try exec("UPDATE paired_macs SET is_active = 1 WHERE mac_device_id = ? AND owner_key = ?;",
                     binding: [.text(macDeviceID), .text(ownerKey)])
        }
    }

    /// Clear the active paired Mac in the optional Stack user and team scope.
    public func clearActive(stackUserID: String? = nil, teamID: String? = nil) throws {
        try ensureReady()
        try clearActiveMacs(stackUserID: stackUserID, teamID: teamID)
    }

    /// Persist user-facing customizations for one paired Mac.
    public func setCustomization(
        macDeviceID: String,
        customName: String?,
        customColor: String?,
        customIcon: String?,
        stackUserID: String? = nil,
        teamID: String? = nil,
        now: Date = Date()
    ) throws {
        try ensureReady()
        let macDeviceID = cmxCanonicalDeviceID(macDeviceID)
        let matches = try fetchAllMacs(
            stackUserID: stackUserID,
            teamID: teamID
        ).filter { $0.macDeviceID == macDeviceID }
        guard matches.count == 1, let target = matches.first else { return }
        try setCustomization(
            macDeviceID: macDeviceID,
            instanceTag: target.instanceTag,
            customName: customName,
            customColor: customColor,
            customIcon: customIcon,
            stackUserID: stackUserID,
            teamID: teamID,
            now: now
        )
    }

    /// Persist user-facing customizations for one tagged paired Mac.
    public func setCustomization(
        macDeviceID: String,
        instanceTag: String?,
        customName: String?,
        customColor: String?,
        customIcon: String?,
        stackUserID: String? = nil,
        teamID: String? = nil,
        now: Date = Date()
    ) throws {
        try ensureReady()
        let macDeviceID = cmxCanonicalDeviceID(macDeviceID)
        // Bump last_seen_at so the change is the freshest write for this record and
        // the LWW backup/restore propagates it to the user's other devices. Leaves
        // display_name / routes / is_active untouched (the Mac owns those).
        try exec("""
            UPDATE paired_macs
            SET custom_name = ?, custom_color = ?, custom_icon = ?, last_seen_at = ?
            WHERE mac_device_id = ? AND owner_key = ?;
        """, binding: [
            customName.map(BindValue.text) ?? .null,
            customColor.map(BindValue.text) ?? .null,
            customIcon.map(BindValue.text) ?? .null,
            .real(now.timeIntervalSince1970),
            .text(macDeviceID),
            .text(Self.ownerKey(
                stackUserID: stackUserID,
                teamID: teamID,
                instanceTag: instanceTag
            )),
        ])
    }

    /// Persist THIS iPhone's connection-method choice for one tagged paired
    /// Mac ("iroh"/"tailscale", nil = revert to the app default). Deliberately
    /// does NOT bump `last_seen_at`: the choice is device-local and must not
    /// become the freshest write that LWW backup propagates to other devices.
    public func setConnectionMethod(
        macDeviceID: String,
        instanceTag: String?,
        rawValue: String?,
        stackUserID: String? = nil,
        teamID: String? = nil
    ) throws {
        try ensureReady()
        let macDeviceID = cmxCanonicalDeviceID(macDeviceID)
        try exec("""
            UPDATE paired_macs
            SET connection_method = ?
            WHERE mac_device_id = ? AND owner_key = ?;
        """, binding: [
            rawValue.map(BindValue.text) ?? .null,
            .text(macDeviceID),
            .text(Self.ownerKey(
                stackUserID: stackUserID,
                teamID: teamID,
                instanceTag: instanceTag
            )),
        ])
    }

    /// Persist THIS iPhone's Direct-method dial candidates for one tagged
    /// paired Mac (JSON payload owned by the shell; nil clears the list).
    /// Device-local like `connection_method`: never bumps LWW freshness.
    public func setDirectAddresses(
        macDeviceID: String,
        instanceTag: String?,
        rawJSON: String?,
        stackUserID: String? = nil,
        teamID: String? = nil
    ) throws {
        try ensureReady()
        let macDeviceID = cmxCanonicalDeviceID(macDeviceID)
        try exec("""
            UPDATE paired_macs
            SET direct_addresses = ?
            WHERE mac_device_id = ? AND owner_key = ?;
        """, binding: [
            rawJSON.map(BindValue.text) ?? .null,
            .text(macDeviceID),
            .text(Self.ownerKey(
                stackUserID: stackUserID,
                teamID: teamID,
                instanceTag: instanceTag
            )),
        ])
    }

    /// Remove a paired Mac only when the device-only compatibility lookup is unambiguous.
    public func remove(
        macDeviceID: String,
        stackUserID: String? = nil,
        teamID: String? = nil
    ) throws {
        try ensureReady()
        let macDeviceID = cmxCanonicalDeviceID(macDeviceID)
        let matches = try fetchAllMacs(
            stackUserID: stackUserID,
            teamID: teamID
        ).filter { $0.macDeviceID == macDeviceID }
        guard matches.count == 1, let target = matches.first else { return }
        try remove(
            macDeviceID: macDeviceID,
            instanceTag: target.instanceTag,
            stackUserID: stackUserID,
            teamID: teamID
        )
    }

    /// Remove one tagged paired Mac in a specific owner scope.
    public func remove(
        macDeviceID: String,
        instanceTag: String?,
        stackUserID: String? = nil,
        teamID: String? = nil
    ) async throws {
        try removeExactSync(
            macDeviceID: macDeviceID,
            instanceTag: instanceTag,
            stackUserID: stackUserID,
            teamID: teamID
        )
    }

    /// Remove one tagged paired Mac in a specific owner scope.
    public func remove(
        macDeviceID: String,
        instanceTag: String?,
        stackUserID: String? = nil,
        teamID: String? = nil
    ) throws {
        try removeExactSync(
            macDeviceID: macDeviceID,
            instanceTag: instanceTag,
            stackUserID: stackUserID,
            teamID: teamID
        )
    }

    private func removeExactSync(
        macDeviceID: String,
        instanceTag: String?,
        stackUserID: String? = nil,
        teamID: String? = nil
    ) throws {
        try ensureReady()
        let macDeviceID = cmxCanonicalDeviceID(macDeviceID)
        try exec(
            "DELETE FROM paired_macs WHERE mac_device_id = ? AND owner_key = ?;",
            binding: [.text(macDeviceID), .text(Self.ownerKey(
                stackUserID: stackUserID,
                teamID: teamID,
                instanceTag: instanceTag
            ))]
        )
    }

    /// Remove every locally stored paired Mac and route.
    public func removeAll() throws {
        try ensureReady()
        try exec("DELETE FROM paired_macs;")
    }

    // MARK: - Internals

    func userVersion() throws -> Int32 {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let rc = sqlite3_prepare_v2(db, "PRAGMA user_version;", -1, &statement, nil)
        guard rc == SQLITE_OK else {
            throw MobilePairedMacStoreError.prepareFailed(rc, lastErrorMessage())
        }
        let step = sqlite3_step(statement)
        guard step == SQLITE_ROW else {
            throw MobilePairedMacStoreError.stepFailed(step, lastErrorMessage())
        }
        return sqlite3_column_int(statement, 0)
    }

    func setUserVersion(_ version: Int32) throws {
        try exec("PRAGMA user_version = \(version);")
    }

    nonisolated static func ownerKey(
        stackUserID: String?,
        teamID: String?,
        instanceTag: String?
    ) -> String {
        let normalizedTag = CmxMacAppInstanceIdentity(
            macDeviceID: "",
            instanceTag: instanceTag
        ).instanceTag
        return "\(stackUserID ?? "")\u{1F}\(teamID ?? "")\u{1F}\(normalizedTag ?? "")"
    }
}
