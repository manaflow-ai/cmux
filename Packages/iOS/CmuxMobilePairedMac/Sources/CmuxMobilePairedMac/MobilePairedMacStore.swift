public import CMUXMobileCore
public import Foundation
import SQLite3

/// SQLite-backed store of paired Macs. Schema migrations gated on
/// `PRAGMA user_version`.
///
/// An `actor` serializes all access to the (non-`Sendable`, not-thread-safe)
/// SQLite connection, so it is genuinely `Sendable` without opting out of
/// concurrency checking. Construct it once at the app composition root and
/// inject it as `any MobilePairedMacStoring`.
public actor MobilePairedMacStore: MobilePairedMacStoring {
    /// The schema version this build creates and migrates to.
    public static let currentSchemaVersion: Int32 = 6

    // `nonisolated(unsafe)` only so the (Swift 6 nonisolated) `deinit` can close
    // the handle. Every other access goes through actor-isolated methods, and
    // the connection itself is opened `SQLITE_OPEN_FULLMUTEX`, so this is safe.
    private nonisolated(unsafe) var db: OpaquePointer?
    var didMigrate = false
    let attachTokenSecrets: any MobileAttachTokenSecretStoring

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
    /// - Parameter databaseURL: On-disk SQLite file location.
    /// - Throws: ``MobilePairedMacStoreError`` if the connection cannot be opened.
    public init(databaseURL: URL) throws {
        try self.init(
            databaseURL: databaseURL,
            attachTokenSecrets: MobilePairedMacKeychainAttachTokenSecretStore(
                service: Self.attachTokenKeychainService(bundleIdentifier: Bundle.main.bundleIdentifier)
            )
        )
    }

    init(databaseURL: URL, attachTokenSecrets: any MobileAttachTokenSecretStoring) throws {
        self.attachTokenSecrets = attachTokenSecrets
        self.db = try MobilePairedMacSQLiteConnectionOpener().open(path: databaseURL.path)
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

    func exec(_ sql: String, binding parameters: [BindValue] = []) throws {
        if parameters.isEmpty {
            let rc = sqlite3_exec(db, sql, nil, nil, nil)
            guard rc == SQLITE_OK else {
                throw MobilePairedMacStoreError.stepFailed(rc, lastErrorMessage())
            }
            return
        }
        let statement = try prepareStatement(sql)
        defer { sqlite3_finalize(statement) }
        try bind(statement: statement, parameters: parameters)
        let step = sqlite3_step(statement)
        guard step == SQLITE_DONE || step == SQLITE_ROW else {
            throw MobilePairedMacStoreError.stepFailed(step, lastErrorMessage())
        }
    }

    func prepareStatement(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard rc == SQLITE_OK else {
            throw MobilePairedMacStoreError.prepareFailed(rc, lastErrorMessage())
        }
        return statement
    }

    func transaction(_ block: () throws -> Void) throws {
        try exec("BEGIN IMMEDIATE;")
        do {
            try block()
            try exec("COMMIT;")
        } catch {
            _ = sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
            throw error
        }
    }

    func lastErrorMessage() -> String {
        guard let cString = sqlite3_errmsg(db) else { return "" }
        return String(cString: cString)
    }

    func changedRowCount() -> Int32 {
        sqlite3_changes(db)
    }

    /// Insert or update one paired Mac within the explicit account/team owner scope.
    public func upsert(
        macDeviceID: String,
        displayName: String?,
        routes: [CmxAttachRoute],
        attachToken: String? = nil,
        attachTokenExpiresAt: Date? = nil,
        attachTokenWorkspaceID: String? = nil,
        attachTokenTerminalID: String? = nil,
        markActive: Bool,
        stackUserID: String?,
        teamID: String? = nil,
        now: Date = Date()
    ) async throws {
        try ensureReady()
        let ownerKey = "\(stackUserID ?? "")\u{1F}\(teamID ?? "")"
        let legacyOwnerKey = "\(stackUserID ?? "")\u{1F}"
        let existing = try fetchMacRow(macDeviceID: macDeviceID, ownerKey: ownerKey)
        let legacy = existing == nil && teamID != nil
            ? try fetchMacRow(macDeviceID: macDeviceID, ownerKey: legacyOwnerKey)
            : nil
        let shouldClaimLegacy = legacy != nil
        if attachToken == nil, shouldClaimLegacy {
            await copyAttachTokenSecret(
                macDeviceID: macDeviceID,
                fromOwnerKey: legacyOwnerKey,
                toOwnerKey: ownerKey
            )
        }
        let attachTokenChanged = attachToken != nil
        let shouldStoreAttachTokenMetadata: Bool
        if let attachToken {
            shouldStoreAttachTokenMetadata = await saveAttachTokenSecret(
                attachToken,
                macDeviceID: macDeviceID,
                ownerKey: ownerKey
            )
            if !shouldStoreAttachTokenMetadata {
                await deleteAttachTokenSecret(macDeviceID: macDeviceID, ownerKey: ownerKey)
            }
        } else {
            shouldStoreAttachTokenMetadata = false
        }
        try transaction {
            if markActive {
                try clearActiveMacs(stackUserID: stackUserID, teamID: teamID)
            }
            var claimedLegacy: MobilePairedMacStoreMacRow?
            if existing == nil, teamID != nil, let legacy {
                try moveMacRowScope(
                    macDeviceID: macDeviceID,
                    fromOwnerKey: legacy.ownerKey,
                    toOwnerKey: ownerKey,
                    teamID: teamID
                )
                claimedLegacy = legacy
            }
            let createdAt = existing?.createdAt ?? claimedLegacy?.createdAt ?? now
            try upsertMacRow(
                macDeviceID: macDeviceID,
                ownerKey: ownerKey,
                displayName: displayName,
                stackUserID: stackUserID,
                teamID: teamID,
                attachTokenChanged: attachTokenChanged,
                attachTokenExpiresAt: shouldStoreAttachTokenMetadata ? attachTokenExpiresAt : nil,
                attachTokenWorkspaceID: shouldStoreAttachTokenMetadata ? attachTokenWorkspaceID : nil,
                attachTokenTerminalID: shouldStoreAttachTokenMetadata ? attachTokenTerminalID : nil,
                createdAt: createdAt,
                lastSeenAt: now,
                isActive: markActive
            )
            try replaceRoutes(macDeviceID: macDeviceID, ownerKey: ownerKey, routes: routes)
        }
        if shouldClaimLegacy {
            await deleteAttachTokenSecret(macDeviceID: macDeviceID, ownerKey: legacyOwnerKey)
        }
    }

    /// Update one paired Mac's routes without changing its current active flag.
    public func updateRoutes(
        macDeviceID: String,
        displayName: String?,
        routes: [CmxAttachRoute],
        stackUserID: String?,
        teamID: String?,
        now: Date = Date()
    ) async throws {
        try ensureReady()
        let ownerKey = "\(stackUserID ?? "")\u{1F}\(teamID ?? "")"
        let legacyOwnerKey = "\(stackUserID ?? "")\u{1F}"
        let existing = try fetchMacRow(macDeviceID: macDeviceID, ownerKey: ownerKey)
        let legacy = existing == nil && teamID != nil
            ? try fetchMacRow(macDeviceID: macDeviceID, ownerKey: legacyOwnerKey)
            : nil
        let shouldDeleteLegacySecret = legacy != nil
        if shouldDeleteLegacySecret {
            await copyAttachTokenSecret(
                macDeviceID: macDeviceID,
                fromOwnerKey: legacyOwnerKey,
                toOwnerKey: ownerKey
            )
        }
        try transaction {
            if try fetchMacRow(macDeviceID: macDeviceID, ownerKey: ownerKey) == nil,
               teamID != nil,
               try fetchMacRow(macDeviceID: macDeviceID, ownerKey: legacyOwnerKey) != nil {
                try moveMacRowScope(
                    macDeviceID: macDeviceID,
                    fromOwnerKey: legacyOwnerKey,
                    toOwnerKey: ownerKey,
                    teamID: teamID
                )
            }
            guard let existing = try fetchMacRow(macDeviceID: macDeviceID, ownerKey: ownerKey) else {
                return
            }
            try upsertMacRow(
                macDeviceID: macDeviceID,
                ownerKey: ownerKey,
                displayName: displayName,
                stackUserID: stackUserID,
                teamID: teamID,
                attachTokenChanged: false,
                attachTokenExpiresAt: nil,
                attachTokenWorkspaceID: nil,
                attachTokenTerminalID: nil,
                createdAt: existing.createdAt,
                lastSeenAt: now,
                isActive: existing.isActive
            )
            try replaceRoutes(macDeviceID: macDeviceID, ownerKey: ownerKey, routes: routes)
        }
        if shouldDeleteLegacySecret {
            await deleteAttachTokenSecret(macDeviceID: macDeviceID, ownerKey: legacyOwnerKey)
        }
    }

    /// Load every paired Mac visible to the optional Stack user and team scope.
    public func loadAll(stackUserID: String? = nil, teamID: String? = nil) async throws -> [MobilePairedMac] {
        try ensureReady()
        return try await fetchAllMacs(stackUserID: stackUserID, teamID: teamID)
    }

    /// Load the active paired Mac in the optional Stack user and team scope.
    public func activeMac(stackUserID: String? = nil, teamID: String? = nil) async throws -> MobilePairedMac? {
        try ensureReady()
        return try await fetchAllMacs(activeOnly: true, stackUserID: stackUserID, teamID: teamID).first
    }

    /// Mark one paired Mac active within its explicit account/team owner scope.
    public func setActive(macDeviceID: String, stackUserID: String? = nil, teamID: String? = nil) throws {
        try ensureReady()
        let ownerKey = "\(stackUserID ?? "")\u{1F}\(teamID ?? "")"
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
            .text("\(stackUserID ?? "")\u{1F}\(teamID ?? "")"),
        ])
    }

    /// Remove one paired Mac in a specific owner scope, or all matching legacy rows when unscoped.
    public func remove(macDeviceID: String, stackUserID: String? = nil, teamID: String? = nil) async throws {
        try ensureReady()
        let rows = try fetchMacRowsForRemoval(macDeviceID: macDeviceID, stackUserID: stackUserID, teamID: teamID)
        if stackUserID == nil && teamID == nil {
            try exec("DELETE FROM paired_macs WHERE mac_device_id = ?;",
                     binding: [.text(macDeviceID)])
        } else {
            try exec(
                "DELETE FROM paired_macs WHERE mac_device_id = ? AND owner_key = ?;",
                binding: [.text(macDeviceID), .text("\(stackUserID ?? "")\u{1F}\(teamID ?? "")")]
            )
        }
        await deleteAttachTokenSecrets(for: rows)
    }

    /// Remove every locally stored paired Mac and route.
    public func removeAll() async throws {
        try ensureReady()
        let rows = try fetchAllMacRows()
        try exec("DELETE FROM paired_macs;")
        await deleteAttachTokenSecrets(for: rows)
    }
}
