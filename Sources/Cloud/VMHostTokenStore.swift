import Foundation
import Security
import os

/// Per-machine bearer tokens for the Cloud VM host listener.
///
/// This Mac mints one token per machine, delivers it into the machine over
/// the link it already holds (`CloudMachineLinkManager`), and later maps a
/// presented token back to the machine that may use it. Tokens are stored in
/// `~/.cmuxterm/vm-host/tokens.json` (0600, directory 0700) — the same trust
/// model as the WireGuard private key next door — so a relaunch keeps
/// accepting the tokens machines already hold instead of forcing a redeliver.
final class VMHostTokenStore: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<[String: String]>(initialState: [:])
    private let fileURL: URL
    private let directoryURL: URL
    private let loaded = OSAllocatedUnfairLock(initialState: false)

    init(home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)) {
        directoryURL = home.appendingPathComponent(".cmuxterm", isDirectory: true)
            .appendingPathComponent("vm-host", isDirectory: true)
        fileURL = directoryURL.appendingPathComponent("tokens.json", isDirectory: false)
    }

    /// The token for `vmID`, minted on first use. 32 random bytes, base64url.
    func token(for vmID: String) -> String {
        loadIfNeeded()
        return lock.withLock { tokens in
            if let existing = tokens[vmID] { return existing }
            let minted = Self.mintToken()
            tokens[vmID] = minted
            persist(tokens)
            return minted
        }
    }

    /// The machine a presented token belongs to, or nil. Scans every entry so
    /// timing does not reveal which prefix matched.
    func vmID(forToken presented: String) -> String? {
        loadIfNeeded()
        return lock.withLock { tokens in
            var match: String?
            for (vmID, token) in tokens where VMHostAccessPolicy.tokensMatch(presented, token) {
                match = vmID
            }
            return match
        }
    }

    func remove(vmID: String) {
        loadIfNeeded()
        lock.withLock { tokens in
            guard tokens.removeValue(forKey: vmID) != nil else { return }
            persist(tokens)
        }
    }

    /// Drop every token; used on sign-out and tunnel revoke so a later account
    /// never inherits a previous one's machines.
    func removeAll() {
        loaded.withLock { $0 = true }
        lock.withLock { tokens in
            tokens = [:]
            persist(tokens)
        }
    }

    /// Keep only the machines the account still owns.
    func retain(vmIDs: Set<String>) {
        loadIfNeeded()
        lock.withLock { tokens in
            let before = tokens.count
            tokens = tokens.filter { vmIDs.contains($0.key) }
            if tokens.count != before { persist(tokens) }
        }
    }

    var count: Int {
        loadIfNeeded()
        return lock.withLock { $0.count }
    }

    // MARK: - internals

    static func mintToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func loadIfNeeded() {
        let alreadyLoaded = loaded.withLock { flag -> Bool in
            if flag { return true }
            flag = true
            return false
        }
        guard !alreadyLoaded else { return }
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else { return }
        lock.withLock { tokens in
            if tokens.isEmpty { tokens = decoded }
        }
    }

    /// Called with the lock held.
    private func persist(_ tokens: [String: String]) {
        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let data = try JSONEncoder().encode(tokens)
            try data.write(to: fileURL, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            #if DEBUG
            cmuxDebugLog("vmhost.tokens.persistFailed error=\(error.localizedDescription)")
            #endif
        }
    }
}
