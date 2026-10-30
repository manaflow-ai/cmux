public import CryptoKit
public import Foundation
import Security

/// Undoable cookie clears on the app's tabs (private data, bead cx-pp5;
/// Lawrence via ff 2026-10-07: every clear is easy to undo, and only the
/// person deletes a backup). The same contract as the browser host's
/// headless backups (cmux-tui/crates/cmux-browser-host/src/cookie_backups.rs),
/// kept by the app because the app owns its profiles' cookie stores:
///
/// - Where: `<Application Support>/<bundle id>/CookieBackups/<32 hex>.bin`,
///   mode 0600, in a 0700 directory.
/// - Encryption: ChaChaPoly with a 256-bit key from a ``CookieBackupKeySource``
///   (the app uses a Keychain item, decision D4 on issue 13742); the restore
///   id is the associated data, so a file renamed to another id does not
///   open. Never synced, never logged; nothing outside the file holds a
///   cookie value.
/// - Retention: until it is restored, the person deletes it, or every
///   cookie in it has passed its own expiry (checked at each clear and
///   restore; a session cookie keeps it).
/// - Bound: at most ``maxBackups`` backups or ``maxBytes`` of backup files.
///   A clear that would pass it is refused before any cookie is deleted; no
///   older backup is dropped to make room (an agent could otherwise push
///   the undo of an earlier clear out with new clears).
///
/// Restore ids are `app:<32 hex>` (128 bits from the system random source).
public nonisolated struct CookieBackups: Sendable {
    public static let restorePrefix = "app:"
    public static let defaultMaxBackups = 50
    public static let defaultMaxBytes = 64 * 1024 * 1024
    static let magic = Data("CMUXCB1\n".utf8)

    public let directory: URL
    let keySource: any CookieBackupKeySource
    let maxBackups: Int
    let maxBytes: Int

    public init(directory: URL, keySource: any CookieBackupKeySource,
                maxBackups: Int = CookieBackups.defaultMaxBackups, maxBytes: Int = CookieBackups.defaultMaxBytes) {
        self.directory = directory
        self.keySource = keySource
        self.maxBackups = maxBackups
        self.maxBytes = maxBytes
    }

    /// `<Application Support>/<bundle id>/CookieBackups`.
    public static func defaultDirectory(bundleID: String?) -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(filePath: NSTemporaryDirectory())
        let bundle = bundleID.flatMap { $0.isEmpty ? nil : $0 } ?? "com.cmuxterm.app.next"
        return support.appending(path: bundle).appending(path: "CookieBackups", directoryHint: .isDirectory)
    }

    /// Why a new backup of `plainBytes` bytes would pass the bound, or nil.
    public func full(plainBytes: Int) -> String? {
        let files = backupFiles()
        let used = files.reduce(0) { $0 + $1.size }
        let next = plainBytes + Self.magic.count + 12 + 16
        guard files.count >= maxBackups || used + next > maxBytes else { return nil }
        let mib = Double(used) / 1_048_576
        return String(format: "cookie backups are full (%d backups, %.1f MiB); restore a backup with "
                      + "cookies.restore or ask the person to purge backups", files.count, mib)
    }

    /// Encrypts and writes `record`; answers its restore id.
    public func save(_ record: Data) throws(CookieBackupError) -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw CookieBackupError("no random bytes for a backup id")
        }
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let id = Self.restorePrefix + hex
        let key = try keySource.key()
        let sealed: Data
        do {
            sealed = try ChaChaPoly.seal(record, using: key, authenticating: Data(id.utf8)).combined
        } catch {
            throw CookieBackupError("the backup could not be sealed: \(error.localizedDescription)")
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            let url = directory.appending(path: "\(hex).bin")
            guard FileManager.default.createFile(atPath: url.path, contents: Self.magic + sealed,
                                                 attributes: [.posixPermissions: 0o600]) else {
                throw CookieBackupError("the backup file could not be written")
            }
        } catch let error as CookieBackupError {
            throw error
        } catch {
            throw CookieBackupError("the backup file could not be written: \(error.localizedDescription)")
        }
        return id
    }

    /// The decrypted record of `restoreID`.
    public func load(_ restoreID: String) throws(CookieBackupError) -> Data {
        let url = try fileURL(restoreID)
        guard let file = FileManager.default.contents(atPath: url.path) else {
            throw CookieBackupError("no cookie backup \(restoreID) (restored, purged or expired)")
        }
        return try open(file, id: restoreID, key: keySource.key())
    }

    /// Deletes the backup of `restoreID`.
    public func remove(_ restoreID: String) throws(CookieBackupError) {
        let url = try fileURL(restoreID)
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw CookieBackupError("the backup \(restoreID) could not be deleted: \(error.localizedDescription)")
        }
    }

    /// Deletes every backup whose cookies all passed their own expiry
    /// (`expires`, seconds; a cookie without one keeps the backup). A
    /// backup that does not open is left for the person (``summaries()``
    /// lists it as unreadable). Reads the key once.
    @discardableResult
    public func pruneExpired(now: Date = Date()) -> Int {
        guard let key = try? keySource.key() else { return 0 }
        var removed = 0
        for file in backupFiles() {
            guard let record = record(file.url, key: key), let cookies = record["cookies"] as? [[String: Any]] else { continue }
            if cookies.allSatisfy({ Self.expired($0, now: now) }) {
                try? FileManager.default.removeItem(at: file.url)
                removed += 1
            }
        }
        return removed
    }

    /// One backup on the History page's list: never a cookie value.
    public struct Summary: Sendable {
        public let restoreID: String
        /// The host whose cookies were cleared; nil when the backup does not
        /// open with this Mac's key (it still counts toward the bound, so
        /// the person can delete it).
        public let site: String?
        public let createdAt: Date
    }

    /// Every backup, newest first (reads the key once). An unreadable one is
    /// listed with no site and its file's date.
    public func summaries() -> [Summary] {
        let key = try? keySource.key()
        return backupFiles().map { file in
            let id = Self.restorePrefix + file.url.deletingPathExtension().lastPathComponent
            guard let key, let record = record(file.url, key: key) else {
                let modified = (try? file.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return Summary(restoreID: id, site: nil, createdAt: modified)
            }
            let created = ((record["createdAt"] as? NSNumber)?.doubleValue ?? 0) / 1000
            return Summary(restoreID: id, site: record["site"] as? String ?? "", createdAt: Date(timeIntervalSince1970: created))
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    private func record(_ url: URL, key: SymmetricKey) -> [String: Any]? {
        let id = Self.restorePrefix + url.deletingPathExtension().lastPathComponent
        guard let data = FileManager.default.contents(atPath: url.path), let plain = try? open(data, id: id, key: key) else { return nil }
        return try? JSONSerialization.jsonObject(with: plain) as? [String: Any]
    }

    /// Whether a backed-up cookie (`expires` in seconds since 1970, -1 for a
    /// session cookie) has passed its expiry.
    public static func expired(_ cookie: [String: Any], now: Date) -> Bool {
        guard let expires = (cookie["expires"] as? NSNumber)?.doubleValue, expires > 0 else { return false }
        return expires <= now.timeIntervalSince1970
    }

    private func open(_ file: Data, id: String, key: SymmetricKey) throws(CookieBackupError) -> Data {
        guard file.starts(with: Self.magic) else { throw CookieBackupError("the backup \(id) is not a cookie backup") }
        do {
            let box = try ChaChaPoly.SealedBox(combined: file.dropFirst(Self.magic.count))
            return try ChaChaPoly.open(box, using: key, authenticating: Data(id.utf8))
        } catch {
            throw CookieBackupError("the backup \(id) does not open with this Mac's backup key")
        }
    }

    private func fileURL(_ restoreID: String) throws(CookieBackupError) -> URL {
        let hex = restoreID.hasPrefix(Self.restorePrefix) ? String(restoreID.dropFirst(Self.restorePrefix.count)) : ""
        guard hex.count == 32, hex.allSatisfy({ $0.isASCII && $0.isHexDigit && !$0.isUppercase }) else {
            throw CookieBackupError("\(restoreID) is not an app cookie restore id (app:<32 hex>)")
        }
        return directory.appending(path: "\(hex).bin")
    }

    private func backupFiles() -> [(url: URL, size: Int)] {
        let names = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return names.filter { $0.pathExtension == "bin" }.map { url in
            (url, (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }
}

/// Why a backup call failed (agent-facing protocol text, not localized).
public nonisolated struct CookieBackupError: Error, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
}
