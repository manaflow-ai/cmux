public import Foundation
import CryptoKit

/// Stores one authenticated, encrypted cache per full v2 identity on both Mac and iOS.
public actor V2FileStateStore: V2StateStoring {
    private let directory: URL
    private let fileManager: FileManager
    private let encryptionKey: SymmetricKey

    /// Creates a store beneath an injected application-support location.
    /// - Parameters:
    ///   - rootDirectory: The app's own support directory or a test temporary directory.
    ///   - fileManager: The caller's filesystem dependency.
    ///   - identityKey: The exact scope's existing endpoint key, loaded from Keychain in production.
    public init(rootDirectory: URL, fileManager: FileManager, identityKey: V2IdentityKey) {
        directory = rootDirectory.appendingPathComponent("cmux-iroh-v2", isDirectory: true).appendingPathComponent("state", isDirectory: true)
        self.fileManager = fileManager
        // Domain separation keeps cache encryption independent of Ed25519 signing.
        encryptionKey = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: identityKey.secretKey),
            info: Data("cmux-iroh-v2.state-encryption.v1".utf8), outputByteCount: 32)
    }

    /// Opens the matching cache, or migrates its prior plaintext v2 file after a verified write.
    /// - Parameter identity: The complete expected identity.
    /// - Returns: Current state, or nil if it has never been written.
    /// - Throws: An I/O, decoding, or scope error.
    public func load(identity: V2Identity) throws -> V2CachedState? {
        let file = try location(identity, extension: "sealed")
        if fileManager.fileExists(atPath: file.path) {
            let bytes = try Data(contentsOf: file)
            let data: Data
            do {
                data = try AES.GCM.open(AES.GCM.SealedBox(combined: bytes), using: encryptionKey,
                    authenticating: V2WireSigningCodec().encode(identity))
            } catch {
                // Never fall back to an older plaintext authority after an encrypted cache exists.
                return nil
            }
            guard let state = try decode(data, identity: identity) else { return nil }
            // Finish cleanup if an earlier migration stopped after its encrypted write.
            try removePlaintext(identity: identity)
            return state
        }
        let legacy = try location(identity, extension: "json")
        guard fileManager.fileExists(atPath: legacy.path),
              let state = try decode(Data(contentsOf: legacy), identity: identity) else { return nil }
        try save(state)
        return state
    }

    private func decode(_ data: Data, identity: V2Identity) throws -> V2CachedState? {
        let state: V2CachedState
        do { state = try JSONDecoder().decode(V2CachedState.self, from: data) }
        catch is DecodingError { return nil } // Disposable cache; signed setup recovers authority.

        guard state.formatVersion == 2, state.identity == identity else { throw V2ControlFailure.scopeMismatch }
        return state
    }

    /// Encrypts and replaces the current cache, then removes its superseded plaintext copy.
    /// - Parameter state: Current values for this complete identity.
    /// - Throws: An I/O or scope error.
    public func save(_ state: V2CachedState) throws {
        guard state.formatVersion == 2 else { throw V2ControlFailure.scopeMismatch }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var protectedDirectory = directory
        try protectedDirectory.setResourceValues(resourceValues)
        let file = try location(state.identity, extension: "sealed")
        let context = try V2WireSigningCodec().encode(state.identity)
        let sealed = try AES.GCM.seal(JSONEncoder().encode(state), using: encryptionKey, authenticating: context)
        guard let bytes = sealed.combined else { throw V2ControlFailure.persistenceFailed }
        try bytes.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        // Preserve the only readable copy if the write or readback fails.
        let written = try AES.GCM.open(AES.GCM.SealedBox(combined: Data(contentsOf: file)),
            using: encryptionKey, authenticating: context)
        guard try decode(written, identity: state.identity) == state else { throw V2ControlFailure.persistenceFailed }
        try removePlaintext(identity: state.identity)
    }

    private func removePlaintext(identity: V2Identity) throws {
        let legacy = try location(identity, extension: "json")
        if fileManager.fileExists(atPath: legacy.path) { try fileManager.removeItem(at: legacy) }
    }

    private func location(_ identity: V2Identity, extension suffix: String) throws -> URL {
        let digest = SHA256.hash(data: try V2WireSigningCodec().encode(identity))
        return directory.appendingPathComponent(digest.map { String(format: "%02x", $0) }.joined() + "." + suffix)
    }
}
