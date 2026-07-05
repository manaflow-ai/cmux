public import Foundation

/// File-backed token vault used when Keychain is unavailable.
///
/// Tagged Debug builds run with per-tag bundle identifiers and without the
/// data-protection Keychain entitlement, so `SecItem` calls fail with
/// `errSecMissingEntitlement` (-34018). This vault keeps linking functional in
/// those environments by storing tokens in a `0600` JSON file inside the
/// user's cmux state directory, mirroring the app's existing secure-file
/// storage conventions.
public actor InboxFileTokenVault: InboxTokenStoring {
    private let fileURL: URL
    private let fileManager: FileManager

    /// Default vault location next to the inbox database.
    public static func defaultFileURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cmuxterm", isDirectory: true)
            .appendingPathComponent("inbox-tokens.json", isDirectory: false)
    }

    /// Creates a file vault.
    /// - Parameter fileURL: Storage file location; created on first save with 0600 permissions.
    public init(fileURL: URL = InboxFileTokenVault.defaultFileURL()) {
        self.fileURL = fileURL
        self.fileManager = FileManager.default
    }

    /// Saves token bytes, rewriting the vault file atomically with 0600 permissions.
    public func saveToken(_ token: Data, source: InboxSource, accountID: String) async throws {
        var entries = try loadEntries()
        entries[Self.key(source: source, accountID: accountID)] = token.base64EncodedString()
        try persist(entries)
    }

    /// Reads token bytes for the exact source account.
    public func token(source: InboxSource, accountID: String) async throws -> Data? {
        let entries = try loadEntries()
        guard let encoded = entries[Self.key(source: source, accountID: accountID)] else { return nil }
        guard let data = Data(base64Encoded: encoded) else {
            throw InboxError.credentialStoreFailed("Stored token for \(source.rawValue) is corrupted")
        }
        return data
    }

    /// Deletes token bytes for the exact source account.
    public func deleteToken(source: InboxSource, accountID: String) async throws {
        var entries = try loadEntries()
        guard entries.removeValue(forKey: Self.key(source: source, accountID: accountID)) != nil else { return }
        try persist(entries)
    }

    /// Returns redacted token presence without exposing token bytes.
    public func credentialState(source: InboxSource, accountID: String) async -> InboxCredentialState {
        guard let entries = try? loadEntries() else { return .inaccessible }
        return entries[Self.key(source: source, accountID: accountID)] != nil ? .present : .missing
    }

    private static func key(source: InboxSource, accountID: String) -> String {
        "\(source.rawValue):\(accountID)"
    }

    private func loadEntries() throws -> [String: String] {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [:] }
        do {
            let data = try Data(contentsOf: fileURL)
            guard !data.isEmpty else { return [:] }
            return try JSONDecoder().decode([String: String].self, from: data)
        } catch {
            throw InboxError.credentialStoreFailed("Token vault file is unreadable")
        }
    }

    private func persist(_ entries: [String: String]) throws {
        do {
            let directory = fileURL.deletingLastPathComponent()
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(entries)
            // `.atomic` Data.write would rename a default-permission temp file
            // over the vault, leaving token bytes world-readable until the
            // chmod below (or forever, if the process dies in between). Create
            // the temp file with 0600 up front, then swap it in atomically.
            let temporaryURL = directory.appendingPathComponent(".\(fileURL.lastPathComponent).tmp")
            guard fileManager.createFile(
                atPath: temporaryURL.path,
                contents: data,
                attributes: [.posixPermissions: 0o600]
            ) else {
                throw InboxError.credentialStoreFailed("Token vault write failed")
            }
            _ = try fileManager.replaceItemAt(fileURL, withItemAt: temporaryURL)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            throw InboxError.credentialStoreFailed("Token vault write failed")
        }
    }
}
