public import CMUXMobileCore
public import CmuxIrohTransport
public import Foundation

/// Builds the server-side grant judgment: verify the broker-signed pair grant
/// OFFLINE against pinned verification keys, bind it to the TLS-authenticated
/// initiator key and this host's exact acceptor tuple, and enforce the local
/// revocation set. No backend call sits on this path (steady-state
/// independence); revocations arrive out of band and bite at the NEXT
/// admission.
public struct IrxGrantJudge: Sendable {
    private let verifier = CmxIrohGrantVerifier()
    private let acceptor: CmxIrohGrantPeer
    private let trustProvider: @Sendable () -> IrxTrustSnapshot?
    private let revokedGrantIDs: @Sendable () -> Set<String>

    public init(
        acceptor: CmxIrohGrantPeer,
        trustProvider: @escaping @Sendable () -> IrxTrustSnapshot?,
        revokedGrantIDs: @escaping @Sendable () -> Set<String> = { [] }
    ) {
        self.acceptor = acceptor
        self.trustProvider = trustProvider
        self.revokedGrantIDs = revokedGrantIDs
    }

    public func judgment() -> IrxGrantJudgment {
        let verifier = verifier
        let acceptor = acceptor
        let trustProvider = trustProvider
        let revokedGrantIDs = revokedGrantIDs
        return { grantJWS, remoteEndpointIDHex in
            // Grant verification needs a grant; a grantless (list-auth v2)
            // hello reaching this judge is a composition error, denied loud.
            guard let grantJWS else {
                throw IrxAdmissionDenied(code: .invalidGrant)
            }
            guard let trust = trustProvider() else {
                throw IrxAdmissionDenied(code: .invalidGrant)
            }
            let initiatorID: CmxIrohPeerIdentity
            do {
                initiatorID = try CmxIrohPeerIdentity(endpointID: remoteEndpointIDHex)
            } catch {
                throw IrxAdmissionDenied(code: .identityMismatch)
            }
            let claims: CmxIrohPairGrantClaims
            do {
                claims = try verifier.verifyPairGrant(
                    grantJWS,
                    keys: trust.verificationKeys,
                    authenticatedInitiatorID: initiatorID,
                    acceptor: acceptor,
                    now: Date()
                )
            } catch let error as CmxIrohGrantVerifierError {
                switch error {
                case .expired:
                    throw IrxAdmissionDenied(code: .grantExpired)
                case .identityMismatch, .accountMismatch:
                    throw IrxAdmissionDenied(code: .identityMismatch)
                default:
                    throw IrxAdmissionDenied(code: .invalidGrant)
                }
            }
            if revokedGrantIDs().contains(claims.grantID) {
                throw IrxAdmissionDenied(code: .revoked)
            }
            return IrxAdmittedPeerInfo(
                bindingID: claims.initiator.bindingID,
                deviceID: claims.initiator.deviceID,
                tag: claims.initiator.tag,
                endpointIDHex: remoteEndpointIDHex,
                identityGeneration: claims.initiator.identityGeneration
            )
        }
    }
}
