import Foundation

/// File-backed token store: writes to a JSON document with 0600 mode in
/// Application Support, namespaced by bundle id. Chosen over both the login
/// keychain (prompts on every ad-hoc Debug rebuild) and the data-protection
/// keychain (fails with errSecMissingEntitlement without a keychain-access-
/// groups entitlement we don't have on Debug). Atomic writes so a
/// pkill-during-reload can't drop the refresh token.
actor FileStackTokenStore: StackAuthTokenStoreProtocol {
    private struct Snapshot: Codable {
        var accessToken: String?
        var refreshToken: String?
    }

    private let log = AuthDebugLog()

    private let fileURL: URL = {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let bundleID = Bundle.main.bundleIdentifier ?? "cmux"
        return support
            .appendingPathComponent("cmux", isDirectory: true)
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("credentials.json", isDirectory: false)
    }()

    private var cache: Snapshot?

    func getStoredAccessToken() async -> String? {
        loadIfNeeded().accessToken
    }

    func getStoredRefreshToken() async -> String? {
        loadIfNeeded().refreshToken
    }

    func setTokens(accessToken: String?, refreshToken: String?) async {
        log.log("file.setTokens: hasAccess=\(accessToken?.isEmpty == false) hasRefresh=\(refreshToken?.isEmpty == false)")
        var snapshot = loadIfNeeded()
        snapshot.accessToken = (accessToken?.isEmpty == false) ? accessToken : nil
        snapshot.refreshToken = (refreshToken?.isEmpty == false) ? refreshToken : nil
        write(snapshot)
    }

    func clearTokens() async {
        log.log("clearTokens called")
        write(Snapshot(accessToken: nil, refreshToken: nil))
    }

    @discardableResult
    func clearTokensIfCurrent(accessToken: String?, refreshToken: String?) async -> Bool {
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

    func compareAndSet(
        compareRefreshToken: String,
        newRefreshToken: String?,
        newAccessToken: String?
    ) async {
        let current = loadIfNeeded().refreshToken
        let matches = current == compareRefreshToken
        log.log("file.compareAndSet: matches=\(matches) hasNewRefresh=\(newRefreshToken?.isEmpty == false) hasNewAccess=\(newAccessToken?.isEmpty == false)")
        guard matches else { return }
        if newRefreshToken == nil && newAccessToken == nil {
            log.log("file.compareAndSet: blocked double-nil clear (preserving session)")
            return
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
