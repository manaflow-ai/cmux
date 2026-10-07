public import Foundation

/// The statement each side signs to bind its DTLS fingerprint to its
/// identity key (b2-webrtc.md section 8):
///
/// ```
/// cmux.webrtc/1 \n role \n session \n hostID \n fingerprint \n offerFingerprint
/// ```
///
/// `role` is `offer` or `answer`; `offerFingerprint` is empty for an offer,
/// so an answer also commits to the offer it answers.
public struct FingerprintBinding: Sendable, Hashable {
    public enum Role: String, Sendable, Hashable {
        case offer
        case answer
    }

    public static let context = "cmux.webrtc/1"

    public var role: Role
    public var session: String
    public var hostID: String
    public var fingerprint: DTLSFingerprint
    public var offerFingerprint: DTLSFingerprint?

    public init(role: Role, session: String, hostID: String, fingerprint: DTLSFingerprint, offerFingerprint: DTLSFingerprint? = nil) {
        self.role = role
        self.session = session
        self.hostID = hostID
        self.fingerprint = fingerprint
        self.offerFingerprint = offerFingerprint
    }

    public var statement: Data {
        let fields = [Self.context, role.rawValue, session, hostID, fingerprint.value, offerFingerprint?.value ?? ""]
        return Data(fields.joined(separator: "\n").utf8)
    }

    /// Signs the binding of `sdp`.
    public func sign(with identity: any WebRTCIdentity) throws -> SignalAuth {
        SignalAuth(key: identity.publicKey.x963Representation, signature: try identity.sign(statement))
    }

    /// Checks `auth` against this binding; returns the signer's key.
    public func verify(_ auth: SignalAuth?) throws -> WebRTCPublicKey {
        guard let auth else { throw WebRTCAuthError.missingAuth }
        guard let key = WebRTCPublicKey(x963Representation: auth.key) else { throw WebRTCAuthError.invalidKey }
        guard key.isValidSignature(auth.signature, for: statement) else { throw WebRTCAuthError.badSignature }
        return key
    }
}
