import CmuxInstallAuthCore
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
public import Foundation
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif

/// Why the app cannot make a presence proof for a hand level raise.
public enum HandPresenceError: Error, Equatable, Sendable {
    /// This Mac has no Secure Enclave (or the enclave refused the key). Raises are refused: there is
    /// no software key fallback (a trust change for #13742).
    case unavailable
    /// The person cancelled Touch ID / the password prompt, or the app cancelled it.
    case cancelled
    case failed(String)
}

/// The person's presence behind the presence key (docs/chief-hands.md "Permission levels"): the key is
/// made where only this device can use it, and each signature asks the person first. The composition
/// root injects it: ``EnclaveUserPresence`` on macOS (Secure Enclave, Touch ID or the login password);
/// ``NoUserPresence`` where there is no Secure Enclave (Linux), which refuses as a Mac without one does.
public protocol UserPresence: Sendable {
    /// Whether this device can make and use a presence key at all (on macOS, whether it has a Secure Enclave).
    var isAvailable: Bool { get }
    /// A new presence key: the wrapped key blob this device alone can use, and its public point (X9.63).
    func makeKey() throws(HandPresenceError) -> (blob: Data, publicKeyX963: Data)
    /// Asks for presence with `prompt`'s reason, then signs `message` with the key `blob`: raw `r || s`,
    /// base64url. ``HandPresencePrompt/cancel()`` cancels the ask.
    func sign(_ message: String, blob: Data, prompt: HandPresencePrompt) async throws(HandPresenceError) -> String
}

/// No presence on this device: every key and signature is refused with ``HandPresenceError/unavailable``.
public struct NoUserPresence: UserPresence {
    public init() {}

    public var isAvailable: Bool { false }

    public func makeKey() throws(HandPresenceError) -> (blob: Data, publicKeyX963: Data) {
        throw .unavailable
    }

    public func sign(_ message: String, blob: Data, prompt: HandPresencePrompt) async throws(HandPresenceError) -> String {
        throw .unavailable
    }
}

/// The presence key of this install: one per Stack user, made by `presence`. The record keeps only the
/// wrapped key blob (usable by this device alone, and only with presence), its public point and the
/// install it was registered for, in a 0600 file.
public struct HandPresenceKeyStore: Sendable {
    struct Record: Codable, Equatable {
        var blob: Data
        var x: String
        var y: String
        /// The install the server holds this key for; nil before a registration answered.
        var install: String?
    }

    let directory: URL
    let presence: any UserPresence

    public init(directory: URL, presence: any UserPresence) {
        self.directory = directory
        self.presence = presence
    }

    /// Whether `presence` can make and use a key on this device.
    public var isAvailable: Bool { presence.isAvailable }

    func file(for user: String) -> URL {
        let digest = SHA256.hash(data: Data(user.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("hand-presence-key-\(digest).json")
    }

    func record(for user: String) -> Record? {
        (try? Data(contentsOf: file(for: user))).flatMap { try? JSONDecoder().decode(Record.self, from: $0) }
    }

    func save(_ record: Record, for user: String) throws {
        try OwnerOnlyFile.write(JSONEncoder().encode(record), to: file(for: user))
    }

    /// `user`'s key record, made by `presence` when there is none.
    func recordOrCreate(for user: String) throws -> Record {
        if let record = record(for: user) { return record }
        let made = try presence.makeKey()
        let jwk = try PublicJWK(x963: made.publicKeyX963)
        let record = Record(blob: made.blob, x: jwk.x, y: jwk.y, install: nil)
        try save(record, for: user)
        return record
    }

    /// Signs `message` with `record`'s key after `prompt` asks for presence.
    func sign(_ message: String, record: Record, prompt: HandPresencePrompt) async throws(HandPresenceError) -> String {
        try await presence.sign(message, blob: record.blob, prompt: prompt)
    }
}

/// One presence prompt in flight: its reason text, and a cancel (on macOS `LAContext.invalidate`, which
/// the framework allows from any thread; where there is no prompt, nothing to cancel).
// crash-allow: the only mutable state is the LAContext, whose invalidate() and evaluation are thread-safe; the reason is immutable.
public final class HandPresencePrompt: @unchecked Sendable {
    public let reason: String
    #if canImport(LocalAuthentication)
    let context = LAContext()
    #endif

    init(reason: String) { self.reason = reason }

    public func cancel() {
        #if canImport(LocalAuthentication)
        context.invalidate()
        #endif
    }
}
