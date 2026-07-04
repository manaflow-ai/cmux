import Darwin
import Foundation

/// Reads/creates the persisted connection-token file, reusing a valid existing
/// token (32-hex, owner-only perms) and replacing anything invalid.
enum VSCodeConnectionTokenStore {
    @discardableResult
    static func ensureToken(at url: URL, fileManager: FileManager = .default) -> String? {
        if let existing = readValidToken(at: url, fileManager: fileManager) {
            return existing
        }
        return writeToken(VSCodeConnectionToken.generate(), to: url, fileManager: fileManager)
    }

    static func readValidToken(at url: URL, fileManager: FileManager) -> String? {
        guard let data = try? Data(contentsOf: url),
              let raw = String(data: data, encoding: .utf8) else {
            return nil
        }
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard VSCodeConnectionToken.isValid(token),
              hasOwnerOnlyPermissions(at: url, fileManager: fileManager) else {
            return nil
        }
        return token
    }

    static func hasOwnerOnlyPermissions(at url: URL, fileManager: FileManager) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let permissions = attributes[.posixPermissions] as? NSNumber else {
            return false
        }
        // No group/other bits set (e.g. 0600/0400).
        return permissions.uint16Value & 0o077 == 0
    }

    @discardableResult
    static func writeToken(_ token: String, to url: URL, fileManager: FileManager) -> String? {
        guard let tokenData = token.data(using: .utf8) else { return nil }
        try? fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // Drop any stale/invalid file so the strict-perms create below succeeds.
        try? fileManager.removeItem(at: url)

        let fileDescriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard fileDescriptor >= 0 else { return nil }
        defer { _ = close(fileDescriptor) }

        let wroteAllBytes = tokenData.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return false }
            return write(fileDescriptor, baseAddress, rawBuffer.count) == rawBuffer.count
        }
        guard wroteAllBytes else {
            try? fileManager.removeItem(at: url)
            return nil
        }
        // Pin to 0600 in case umask widened the create mode.
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return token
    }
}
