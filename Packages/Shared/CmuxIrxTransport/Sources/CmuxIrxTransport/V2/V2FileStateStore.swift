public import Foundation
import CryptoKit

/// Stores one atomically replaced, owner-readable cache per full v2 identity.
public actor V2FileStateStore: V2StateStoring {
    private let directory: URL
    private let fileManager: FileManager

    /// Creates a store beneath an injected application-support location.
    /// - Parameters:
    ///   - rootDirectory: The app's own support directory or a test temporary directory.
    ///   - fileManager: The caller's filesystem dependency.
    public init(rootDirectory: URL, fileManager: FileManager) {
        directory = rootDirectory.appendingPathComponent("cmux-iroh-v2", isDirectory: true).appendingPathComponent("state", isDirectory: true)
        self.fileManager = fileManager
    }

    /// Loads only the matching v2 file and rejects incorrect scope or format.
    /// - Parameter identity: The complete expected identity.
    /// - Returns: Current state, or nil if it has never been written.
    /// - Throws: An I/O, decoding, or scope error.
    public func load(identity: V2Identity) throws -> V2CachedState? {
        let file = try location(identity)
        guard fileManager.fileExists(atPath: file.path) else { return nil }
        let state = try JSONDecoder().decode(V2CachedState.self, from: Data(contentsOf: file))
        guard state.formatVersion == 2, state.identity == identity else { throw V2ControlFailure.scopeMismatch }
        return state
    }

    /// Replaces the one current cache without accumulating issuance records.
    /// - Parameter state: Current values for this complete identity.
    /// - Throws: An I/O or scope error.
    public func save(_ state: V2CachedState) throws {
        guard state.formatVersion == 2 else { throw V2ControlFailure.scopeMismatch }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = try location(state.identity)
        try JSONEncoder().encode(state).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    private func location(_ identity: V2Identity) throws -> URL {
        let digest = SHA256.hash(data: try V2WireSigningCodec().encode(identity))
        return directory.appendingPathComponent(digest.map { String(format: "%02x", $0) }.joined() + ".json")
    }
}
