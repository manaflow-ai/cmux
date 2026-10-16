import CmuxInstallAuthCore
import CryptoKit
public import Foundation
import LocalAuthentication
import Security

/// Why the app cannot make a presence proof for a hand level raise.
public enum HandPresenceError: Error, Equatable, Sendable {
    /// This Mac has no Secure Enclave (or the enclave refused the key). Raises are refused: there is
    /// no software key fallback (a trust change for #13742).
    case unavailable
    /// The person cancelled Touch ID / the password prompt, or the app cancelled it.
    case cancelled
    case failed(String)
}

/// The presence key of this install (docs/chief-hands.md "Permission levels"): a P-256 key in the
/// Secure Enclave with `[.privateKeyUsage, .userPresence]`, so every signature needs Touch ID, Face
/// ID or the login password. One key per Stack user. The record keeps only the enclave's wrapped key
/// blob (usable by this Mac's enclave alone, and only with presence), its public point and the
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

    public init(directory: URL) { self.directory = directory }

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

    /// `user`'s key record, made in the enclave when there is none.
    func recordOrCreate(for user: String) throws -> Record {
        if let record = record(for: user) { return record }
        let made = try HandPresenceKey.create()
        try save(made, for: user)
        return made
    }
}

/// Secure Enclave operations of the presence key.
enum HandPresenceKey {
    static func accessControl() throws -> SecAccessControl {
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                                                           [.privateKeyUsage, .userPresence], &error) else {
            throw HandPresenceError.failed("no access control")
        }
        return access
    }

    static func create() throws -> HandPresenceKeyStore.Record {
        guard SecureEnclave.isAvailable else { throw HandPresenceError.unavailable }
        let key: SecureEnclave.P256.Signing.PrivateKey
        do {
            key = try SecureEnclave.P256.Signing.PrivateKey(accessControl: try accessControl())
        } catch {
            throw HandPresenceError.failed(String(describing: error))
        }
        let jwk = try PublicJWK(x963: key.publicKey.x963Representation)
        return HandPresenceKeyStore.Record(blob: key.dataRepresentation, x: jwk.x, y: jwk.y, install: nil)
    }

    /// Asks for presence with `reason` through `prompt` (the system prompt names the hand and the
    /// level), then signs `message`: raw `r || s`, base64url. ``HandPresencePrompt/cancel()`` cancels.
    static func sign(_ message: String, blob: Data, reason: String, prompt: HandPresencePrompt) async throws -> String {
        guard SecureEnclave.isAvailable else { throw HandPresenceError.unavailable }
        let context = prompt.context
        do {
            _ = try await context.evaluateAccessControl(try accessControl(), operation: .useKeySign, localizedReason: reason)
        } catch let error as LAError where [.userCancel, .appCancel, .systemCancel, .userFallback].contains(error.code) {
            throw HandPresenceError.cancelled
        } catch let error as HandPresenceError {
            throw error
        } catch {
            throw HandPresenceError.failed(error.localizedDescription)
        }
        // The evaluated context carries the presence: the signature itself asks for nothing more.
        do {
            let key = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: blob, authenticationContext: context)
            return try key.signature(for: Data(message.utf8)).rawRepresentation.base64URLEncoded
        } catch {
            // Also a cancel between the prompt and the signature (it invalidates the context).
            throw HandPresenceError.failed(String(describing: error))
        }
    }
}

/// One presence prompt in flight: its reason text, and a cancel (`LAContext.invalidate`, which
/// the framework allows from any thread).
// crash-allow: the only mutable state is the LAContext, whose invalidate() and evaluation are thread-safe; the reason is immutable.
public final class HandPresencePrompt: @unchecked Sendable {
    public let reason: String
    let context = LAContext()

    init(reason: String) { self.reason = reason }

    public func cancel() { context.invalidate() }
}
