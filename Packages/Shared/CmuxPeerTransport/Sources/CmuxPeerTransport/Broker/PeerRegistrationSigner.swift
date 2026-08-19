public import CMUXMobileCore
import CryptoKit
import Foundation

/// Builds the two-leg registration proof using the endpoint identity key.
///
/// Signing uses CryptoKit Ed25519, which produces byte-identical (RFC 8032
/// deterministic) signatures to the iroh secret key the previous transport
/// signed with, so the broker's verification is unchanged.
public struct PeerRegistrationSigner: Sendable {
    private let signingKey: Curve25519.Signing.PrivateKey
    private let endpointID: String

    /// Creates a signer and proves the supplied secret derives the endpoint.
    ///
    /// - Throws: ``PeerRegistrationError/endpointIdentityMismatch`` when route
    ///   identity and signing identity differ.
    public init(identity: PeerEndpointIdentity, endpointID: String) throws {
        let signingKey: Curve25519.Signing.PrivateKey
        do {
            signingKey = try Curve25519.Signing.PrivateKey(
                rawRepresentation: identity.secretKey.bytes
            )
        } catch {
            throw PeerRegistrationError.endpointIdentityMismatch
        }
        let derivedID = PeerBrokerWire.hex(signingKey.publicKey.rawRepresentation)
        guard derivedID == endpointID else {
            throw PeerRegistrationError.endpointIdentityMismatch
        }
        self.signingKey = signingKey
        self.endpointID = endpointID
    }

    /// Canonically encodes payload bytes and constructs the challenge request.
    public func prepare(
        payload: PeerRegistrationPayload
    ) throws -> PeerPreparedRegistration {
        guard payload.endpointID == endpointID else {
            throw PeerRegistrationError.endpointIdentityMismatch
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let payloadBytes = try encoder.encode(payload)
        guard !payloadBytes.isEmpty, payloadBytes.count <= 32_768 else {
            throw PeerRegistrationError.payloadTooLarge
        }
        let payloadSHA256 = PeerBrokerWire.hex(Data(SHA256.hash(data: payloadBytes)))
        let challenge = PeerBrokerChallengeRequest(
            payload: payload,
            payloadSHA256: payloadSHA256
        )
        return PeerPreparedRegistration(
            challengeRequest: challenge,
            encodedPayload: PeerBrokerWire.base64URL(payloadBytes),
            payloadSHA256: payloadSHA256,
            endpointID: endpointID
        )
    }

    /// Signs the exact broker challenge and prepared payload hash.
    public func sign(
        prepared: PeerPreparedRegistration,
        challenge: PeerBrokerChallengeResponse
    ) throws -> PeerBrokerRegisterRequest {
        guard prepared.endpointID == endpointID,
              PeerBrokerWire.isBrokerUUID(challenge.challengeID),
              let nonce = PeerBrokerWire.decodeBase64URL(challenge.nonce),
              nonce.count == 32 else {
            throw PeerRegistrationError.invalidChallenge
        }
        let challengeID = challenge.challengeID.lowercased()
        let transcript = Data(
            "cmux/iroh/device-registration/v1\n\(challengeID)\n\(challenge.nonce)\n\(prepared.payloadSHA256)".utf8
        )
        let signature = try signingKey.signature(for: transcript)
        return PeerBrokerRegisterRequest(
            challengeID: challengeID,
            nonce: challenge.nonce,
            payload: prepared.encodedPayload,
            signature: PeerBrokerWire.base64URL(signature)
        )
    }

    /// Signs one authenticated broker request with the registered endpoint key.
    func signBrokerRequest(
        bindingID: String,
        method: String,
        path: String,
        timestamp: Int64,
        body: Data
    ) throws -> String {
        guard PeerBrokerWire.isBrokerUUID(bindingID),
              !method.isEmpty,
              method.utf8.allSatisfy({ (65 ... 90).contains($0) }),
              !path.isEmpty,
              path.utf8.allSatisfy({ $0 >= 0x21 && $0 <= 0x7e }),
              timestamp > 0 else {
            throw PeerRegistrationError.invalidChallenge
        }
        let bodySHA256 = PeerBrokerWire.hex(Data(SHA256.hash(data: body)))
        let transcript = Data(
            "cmux/iroh/binding-request/v1\n\(bindingID.lowercased())\n\(method)\n\(path)\n\(timestamp)\n\(bodySHA256)".utf8
        )
        return PeerBrokerWire.base64URL(try signingKey.signature(for: transcript))
    }
}

/// Proof material that lets a fresh broker client act as one registered binding.
public struct PeerBindingRequestAuthorization: Sendable {
    /// The exact broker binding whose endpoint key signs each request.
    public let bindingID: String

    /// The exact app namespace recorded on the authorized binding.
    public let clientNamespace: String

    let signer: PeerRegistrationSigner

    /// Reconstructs request authorization from retained binding and identity state.
    ///
    /// - Throws: ``PeerRegistrationError/endpointIdentityMismatch`` when the
    ///   supplied identity does not derive the recorded endpoint.
    public init(
        bindingID: String,
        clientNamespace: String,
        identity: PeerEndpointIdentity,
        endpointID: CmxIrohPeerIdentity
    ) throws {
        self.bindingID = bindingID
        self.clientNamespace = clientNamespace
        signer = try PeerRegistrationSigner(
            identity: identity,
            endpointID: endpointID.endpointID
        )
    }

    init(
        bindingID: String,
        clientNamespace: String,
        signer: PeerRegistrationSigner
    ) {
        self.bindingID = bindingID
        self.clientNamespace = clientNamespace
        self.signer = signer
    }
}
