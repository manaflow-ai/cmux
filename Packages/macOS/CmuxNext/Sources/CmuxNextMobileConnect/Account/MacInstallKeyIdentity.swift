public import CmuxLinkWebRTC
public import Foundation

/// The install key as B2 sees it: phones pin the host install's P-256 key
/// from the trust store and check the fingerprint binding it signs.
public struct MacInstallKeyIdentity: WebRTCIdentity {
    public let publicKey: WebRTCPublicKey
    private let key: MacInstallKey

    public init(key: MacInstallKey) throws {
        guard let publicKey = WebRTCPublicKey(x963Representation: try key.publicKeyX963()) else {
            throw WebRTCAuthError.invalidKey
        }
        self.publicKey = publicKey
        self.key = key
    }

    public func sign(_ message: Data) throws -> Data { try key.sign(message) }
}
