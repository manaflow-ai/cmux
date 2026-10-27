// The macOS presence key: CryptoKit's SecureEnclave and LocalAuthentication exist only on Apple platforms
// (p15-oracle-141); elsewhere the composition root injects `NoUserPresence`.
#if canImport(LocalAuthentication)
import CmuxInstallAuthCore
import CryptoKit
public import Foundation
import LocalAuthentication
import Security

/// The presence key in the Secure Enclave: a P-256 key with `[.privateKeyUsage, .userPresence]`, so
/// every signature needs Touch ID, Face ID or the login password.
public struct EnclaveUserPresence: UserPresence {
    public init() {}

    public var isAvailable: Bool { SecureEnclave.isAvailable }

    static func accessControl() throws(HandPresenceError) -> SecAccessControl {
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                                                           [.privateKeyUsage, .userPresence], &error) else {
            throw HandPresenceError.failed("no access control")
        }
        return access
    }

    public func makeKey() throws(HandPresenceError) -> (blob: Data, publicKeyX963: Data) {
        guard SecureEnclave.isAvailable else { throw HandPresenceError.unavailable }
        let access = try Self.accessControl()
        let key: SecureEnclave.P256.Signing.PrivateKey
        do {
            key = try SecureEnclave.P256.Signing.PrivateKey(accessControl: access)
        } catch {
            throw HandPresenceError.failed(String(describing: error))
        }
        return (key.dataRepresentation, key.publicKey.x963Representation)
    }

    /// Asks for presence through `prompt` (the system prompt names the hand and the level), then signs.
    public func sign(_ message: String, blob: Data, prompt: HandPresencePrompt) async throws(HandPresenceError) -> String {
        guard SecureEnclave.isAvailable else { throw HandPresenceError.unavailable }
        let context = prompt.context
        let access = try Self.accessControl()
        do {
            _ = try await context.evaluateAccessControl(access, operation: .useKeySign, localizedReason: prompt.reason)
        } catch let error as LAError where [.userCancel, .appCancel, .systemCancel, .userFallback].contains(error.code) {
            throw HandPresenceError.cancelled
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
#endif
