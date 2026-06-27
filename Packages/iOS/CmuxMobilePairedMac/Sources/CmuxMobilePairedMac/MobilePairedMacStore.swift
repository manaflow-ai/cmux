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
    public static let currentSchemaVersion: Int32 = 5

    // `nonisolated(unsafe)` only so the (Swift 6 nonisolated) `deinit` can close
    // the handle. Every other access goes through actor-isolated methods, and
    // the connection itself is opened `SQLITE_OPEN_FULLMUTEX`, so this is safe.
    nonisolated(unsafe) var db: OpaquePointer?
    var didMigrate = false

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

    /// Insert or update one paired Mac within the explicit account/team owner scope.
    public func upsert(
        macDeviceID: String,
        displayName: String?,
        routes: [CmxAttachRoute],
        attachToken: String? = nil,
        attachTokenExpiresAt: Date? = nil,
        markActive: Bool,
        stackUserID: String?,
        teamID: String? = nil,
        now: Date = Date()
    ) throws {
        try ensureReady()
        try transaction {
            if markActive {
                try clearActiveMacs(stackUserID: stackUserID, teamID: teamID)
            }
            let ownerKey = "\(stackUserID ?? "")\u{1F}\(teamID ?? "")"
            let existing = try fetchMacRow(macDeviceID: macDeviceID, ownerKey: ownerKey)
            var claimedLegacy: MobilePairedMacStoreMacRow?
            if existing == nil,
               teamID != nil,
               let legacy = try fetchMacRow(
                    macDeviceID: macDeviceID,
                    ownerKey: "\(stackUserID ?? "")\u{1F}"
               ) {
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
                attachToken: attachToken,
                attachTokenExpiresAt: attachTokenExpiresAt,
                createdAt: createdAt,
                lastSeenAt: now,
                isActive: markActive
            )
            try exec(
                "DELETE FROM mac_routes WHERE mac_device_id = ? AND owner_key = ?;",
                binding: [.text(macDeviceID), .text(ownerKey)]
            )
            for route in routes {
                let encoded = try Self.encodeRoute(route)
                try exec("""
                    INSERT INTO mac_routes (mac_device_id, owner_key, route_id, kind, endpoint_json, priority)
                    VALUES (?, ?, ?, ?, ?, ?);
                """, binding: [
                    .text(macDeviceID),
                    .text(ownerKey),
                    .text(route.id),
                    .text(route.kind.rawValue),
                    .text(encoded),
                    .int(Int64(route.priority)),
                ])
            }
        }
    }

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
    public func remove(macDeviceID: String, stackUserID: String? = nil, teamID: String? = nil) throws {
        try ensureReady()
        if stackUserID == nil && teamID == nil {
            try exec("DELETE FROM paired_macs WHERE mac_device_id = ?;",
                     binding: [.text(macDeviceID)])
        } else {
            try exec(
                "DELETE FROM paired_macs WHERE mac_device_id = ? AND owner_key = ?;",
                binding: [.text(macDeviceID), .text("\(stackUserID ?? "")\u{1F}\(teamID ?? "")")]
            )
        }
    }

    /// Remove every locally stored paired Mac and route.
    public func removeAll() throws {
        try ensureReady()
        try exec("DELETE FROM paired_macs;")
    }
}
