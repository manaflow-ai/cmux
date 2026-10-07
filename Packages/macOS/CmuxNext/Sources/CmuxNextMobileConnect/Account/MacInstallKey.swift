public import CmuxInstallAuthCore
public import CmuxPairing
import CryptoKit
public import Foundation

/// This Mac's install key (b6-pairing.md 2): the P-256 key `install.register`
/// records, which mints install tokens, signs the Mac's `direct` and `wg`
/// link certificates and (through `MacInstallKeyIdentity`) its WebRTC
/// fingerprint bindings. A Secure Enclave key when the enclave makes one,
/// else a software key; either way only `storage` holds it.
public struct MacInstallKey: InstallSigner, LinkKeySigning {
    /// Stored handle: a tag byte, then the enclave's opaque handle or the raw software key.
    private enum Tag: UInt8 { case enclave = 1, software = 2 }

    public let storage: MacInstallKeyStorage
    private let allowsEnclave: Bool

    /// - Parameter allowsEnclave: false keeps the key in software (tests).
    public init(storage: MacInstallKeyStorage, allowsEnclave: Bool = true) {
        self.storage = storage
        self.allowsEnclave = allowsEnclave
    }

    public func publicKeyX963() throws -> Data { try key().publicKeyX963 }

    /// ES256, raw r||s. Synchronous, so the WebRTC binding can use it too.
    public func sign(_ message: Data) throws -> Data { try key().sign(message) }

    /// Destroys the key; the next use makes a new one (a revoked install).
    public func rotate() throws { storage.delete() }

    private func key() throws -> AnyKey {
        if let stored = try storage.read(), let tag = stored.first.flatMap(Tag.init(rawValue:)) {
            let body = stored.dropFirst()
            switch tag {
            case .enclave: return .enclave(try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: Data(body)))
            case .software: return .software(try P256.Signing.PrivateKey(rawRepresentation: Data(body)))
            }
        }
        if allowsEnclave, SecureEnclave.isAvailable, let made = try? SecureEnclave.P256.Signing.PrivateKey() {
            try storage.write(Data([Tag.enclave.rawValue]) + made.dataRepresentation)
            return .enclave(made)
        }
        let made = P256.Signing.PrivateKey()
        try storage.write(Data([Tag.software.rawValue]) + made.rawRepresentation)
        return .software(made)
    }

    private enum AnyKey {
        case enclave(SecureEnclave.P256.Signing.PrivateKey)
        case software(P256.Signing.PrivateKey)

        var publicKeyX963: Data {
            switch self {
            case .enclave(let key): key.publicKey.x963Representation
            case .software(let key): key.publicKey.x963Representation
            }
        }

        func sign(_ message: Data) throws -> Data {
            switch self {
            case .enclave(let key): try key.signature(for: message).rawRepresentation
            case .software(let key): try key.signature(for: message).rawRepresentation
            }
        }
    }
}
