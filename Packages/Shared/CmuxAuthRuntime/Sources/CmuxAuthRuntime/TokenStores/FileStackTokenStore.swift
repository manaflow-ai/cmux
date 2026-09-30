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
    private var cache: Snapshot?

    /// Creates a file store persisting to `credentials.json` inside `directory`.
    /// - Parameter directory: The directory to create (0700) and write into;
    ///   injected so the type never reaches for the user's filesystem layout
    ///   itself and tests can use a temp directory.
    public init(directory: URL) {
        self.fileURL = directory.appendingPathComponent("credentials.json", isDirectory: false)
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

    public func clearTokens() async {
        log.log("clearTokens called")
        write(Snapshot(accessToken: nil, refreshToken: nil))
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
        guard fm.fileExists(atPath: fileURL.path) else { return Snapshot() }
        do {
            let data = try Data(contentsOf: fileURL)
            let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
            return snapshot
        } catch {
            log.log("credentials read failed: \(error)")
            return Snapshot()
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
