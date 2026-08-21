public import Foundation

/// File-backed token store: writes to a JSON document with 0600 mode inside an
/// injected directory.
///
/// On macOS this is chosen over both the login keychain (prompts on every
/// ad-hoc Debug rebuild) and the data-protection keychain (fails with
/// errSecMissingEntitlement without a keychain-access-groups entitlement Debug
/// builds don't have). Atomic writes so a kill-during-reload can't drop the
/// refresh token.
///
/// ```swift
/// let store = FileStackTokenStore(directory: appSupport
///     .appendingPathComponent("cmux", isDirectory: true)
///     .appendingPathComponent(bundleID, isDirectory: true))
/// ```
public actor FileStackTokenStore: StackAuthTokenStoreProtocol {
    private struct Snapshot: Codable {
        var accessToken: String?
        var refreshToken: String?
    }

    private let log = AuthDebugLog()
    private let fileURL: URL
    /// The un-suffixed single-slot file every install used before per-project
    /// slots. Non-nil only when this store is project-keyed; its contents are
    /// adopted into the per-project file on first read and the legacy file is
    /// deleted (mirroring the Keychain store's legacy adoption).
    private let legacyFileURL: URL?
    private var cache: Snapshot?

    /// Creates a file store persisting to ``fileName(projectID:)`` inside
    /// `directory`.
    /// - Parameters:
    ///   - directory: The directory to create (0700) and write into; injected
    ///     so the type never reaches for the user's filesystem layout itself
    ///     and tests can use a temp directory.
    ///   - projectID: The Stack project keying this store's per-project file
    ///     (`credentials.<projectID>.json`); `nil` keeps the historical
    ///     single-file behavior.
    public init(directory: URL, projectID: String? = nil) {
        let fileName = Self.fileName(projectID: projectID)
        self.fileURL = directory.appendingPathComponent(fileName, isDirectory: false)
        if fileName == Self.legacyFileName {
            self.legacyFileURL = nil
        } else {
            self.legacyFileURL = directory.appendingPathComponent(
                Self.legacyFileName,
                isDirectory: false
            )
        }
    }

    private static let legacyFileName = "credentials.json"

    /// The credentials file name for one token slot. A non-nil `projectID`
    /// yields `credentials.<projectID>.json`, with every character outside
    /// `[A-Za-z0-9_-]` replaced by `-` so a project id can never traverse the
    /// path or collide with the legacy name; `nil` or empty returns the
    /// historical `credentials.json`.
    public static func fileName(projectID: String?) -> String {
        guard let projectID, !projectID.isEmpty else { return legacyFileName }
        let sanitized = String(projectID.map { character in
            (character.isASCII && (character.isLetter || character.isNumber))
                || character == "-" || character == "_"
                ? character
                : "-"
        })
        return "credentials.\(sanitized).json"
    }

    public func getStoredAccessToken() async -> String? {
        loadIfNeeded().accessToken
    }

    public func getStoredRefreshToken() async -> String? {
        loadIfNeeded().refreshToken
    }

    public func setTokens(accessToken: String?, refreshToken: String?) async {
        log.log("file.setTokens: hasAccess=\(accessToken?.isEmpty == false) hasRefresh=\(refreshToken?.isEmpty == false)")
        var snapshot = loadIfNeeded()
        snapshot.accessToken = (accessToken?.isEmpty == false) ? accessToken : nil
        snapshot.refreshToken = (refreshToken?.isEmpty == false) ? refreshToken : nil
        write(snapshot)
    }

    /// Clears this store's OWN slot plus the un-suffixed legacy file it may
    /// adopt from. Another project's `credentials.<projectID>.json` is
    /// deliberately untouched, so signing out of one backend environment
    /// never destroys a session parked for the other.
    public func clearTokens() async {
        log.log("clearTokens called")
        write(Snapshot(accessToken: nil, refreshToken: nil))
        deleteLegacyFile()
    }

    @discardableResult
    public func clearTokensIfCurrent(accessToken: String?, refreshToken: String?) async -> Bool {
        let stored = loadIfNeeded()
        let snapshot = AuthTokenSnapshot(
            accessToken: stored.accessToken,
            refreshToken: stored.refreshToken
        )
        guard snapshot.matches(expectedAccessToken: accessToken, expectedRefreshToken: refreshToken) else {
            log.log("file.clearTokensIfCurrent: skipped stale clear")
            return false
        }
        log.log("file.clearTokensIfCurrent: cleared matching tokens")
        write(Snapshot(accessToken: nil, refreshToken: nil))
        deleteLegacyFile()
        return true
    }

    /// Replaces tokens only while the stored refresh token is still `compareRefreshToken`.
    ///
    /// The compare value is the staleness guard. A double-nil replacement is the
    /// Stack SDK's `RefreshOutcome.definitivelyRejected` clear, and must delete
    /// the persisted session once the current refresh token still matches.
    public func compareAndSet(
        compareRefreshToken: String,
        newRefreshToken: String?,
        newAccessToken: String?
    ) async {
        let current = loadIfNeeded().refreshToken
        let matches = current == compareRefreshToken
        log.log("file.compareAndSet: matches=\(matches) hasNewRefresh=\(newRefreshToken?.isEmpty == false) hasNewAccess=\(newAccessToken?.isEmpty == false)")
        guard matches else { return }
        if newRefreshToken == nil && newAccessToken == nil {
            log.log("file.compareAndSet: cleared definitively-rejected session")
        }
        await setTokens(accessToken: newAccessToken, refreshToken: newRefreshToken)
    }

    private func loadIfNeeded() -> Snapshot {
        if let cache { return cache }
        let snapshot = readFromDisk()
        cache = snapshot
        return snapshot
    }

    private func readFromDisk() -> Snapshot {
        let fm = FileManager.default
        if fm.fileExists(atPath: fileURL.path) {
            return decodeSnapshot(at: fileURL) ?? Snapshot()
        }
        // Un-suffixed legacy tier: adopt the single-slot `credentials.json`
        // into this store's per-project file, then delete it (mirroring the
        // Keychain store). Its owner is by construction the last-resolved
        // project — this store's project, because an organic project flip
        // clears the store before any read. A legacy file that fails to
        // decode is left in place rather than destroyed.
        guard let legacyFileURL, fm.fileExists(atPath: legacyFileURL.path) else {
            return Snapshot()
        }
        guard let adopted = decodeSnapshot(at: legacyFileURL) else { return Snapshot() }
        write(adopted)
        do {
            try fm.removeItem(at: legacyFileURL)
        } catch {
            log.log("legacy credentials delete failed: \(error)")
        }
        return adopted
    }

    private func decodeSnapshot(at url: URL) -> Snapshot? {
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(Snapshot.self, from: data)
        } catch {
            log.log("credentials read failed: \(error)")
            return nil
        }
    }

    private func deleteLegacyFile() {
        guard let legacyFileURL else { return }
        let fm = FileManager.default
        guard fm.fileExists(atPath: legacyFileURL.path) else { return }
        do {
            try fm.removeItem(at: legacyFileURL)
        } catch {
            log.log("legacy credentials delete failed: \(error)")
        }
    }

    private func write(_ snapshot: Snapshot) {
        cache = snapshot
        let fm = FileManager.default
        let dir = fileURL.deletingLastPathComponent()
        do {
            try fm.createDirectory(
                at: dir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: fileURL, options: [.atomic])
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            log.log("credentials write failed: \(error)")
        }
    }
}
