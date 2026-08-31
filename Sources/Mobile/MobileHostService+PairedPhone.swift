import Foundation
import CmuxAuthRuntime

@MainActor
extension MobileHostService {
    /// Returns the bundle selected by the most recent authenticated pairing for
    /// `accountID`. A legacy-compatibility record is eligible only after an
    /// authenticated status handshake from a pre-metadata client; before that,
    /// missing identity is deliberately fail-closed.
    func pairedPhoneBundleIdentifier(accountID: String?) -> String? {
        pairedPhoneStore.targetBundleIdentifier(accountID: accountID)
    }

    /// Persists phone identity only after an authenticated host-status response
    /// proves the connection is usable. Public status probes remain identity-free
    /// and cannot influence push or backup routing.
    func recordPairedPhoneIfNeeded(
        request: MobileHostRPCRequest,
        result: MobileHostRPCResult,
        authorization: MobileHostConnectionAuthorizationContext,
        authenticatedSessionIdentity verifiedSessionIdentity: AuthenticatedSessionIdentity?
    ) async {
        guard Self.statusResultIncludesIdentity(result),
              let verifiedSessionIdentity,
              let currentSessionIdentity = await self.authenticatedSessionIdentity(),
              currentSessionIdentity == verifiedSessionIdentity else {
            return
        }
        let accountID = verifiedSessionIdentity.accountID
        guard let handshakeIdentity = Self.authenticatedHandshakeIdentity(
            authorization: authorization,
            request: request,
            sessionIdentity: verifiedSessionIdentity
        ) else {
            return
        }
        let previousTarget = pairedPhoneStore.targetBundleIdentifier(accountID: accountID)
        let hasBundleIdentifierField = request.params.keys.contains {
            $0 == "ios_bundle_identifier"
                || $0 == "ios_bundle_id"
                || $0 == "iosBundleIdentifier"
        }
        let didRecord: Bool
        if hasBundleIdentifierField {
            // A modern client must provide both halves of its immutable app
            // identity. A partial claim is rejected rather than silently
            // downgrading to the legacy target.
            guard let clientID = Self.clientID(from: request.params),
                  let bundleIdentifier = Self.iosBundleIdentifier(from: request.params) else {
                return
            }
            didRecord = pairedPhoneStore.record(
                clientID: clientID,
                bundleIdentifier: bundleIdentifier,
                accountID: accountID,
                handshakeIdentity: handshakeIdentity
            )
        } else {
            // Older iOS clients do not send bundle metadata. Their status
            // response is still authenticated, so retain the migrated/historic
            // target for compatibility until a modern app reports its bundle.
            didRecord = pairedPhoneStore.recordLegacyCompatibility(
                clientID: Self.clientID(from: request.params),
                accountID: accountID,
                handshakeIdentity: handshakeIdentity
            )
        }
        guard didRecord else { return }
        // A startup queue may be waiting for this first authenticated target;
        // re-key it before the next push producer runs.
        PhonePushClient.shared.pairedPhoneTargetDidChange()
        guard pairedPhoneStore.targetBundleIdentifier(accountID: accountID) != previousTarget else {
            return
        }
        // Wake backup publishers and the pairing window when the authoritative
        // target changes, even if the listener routes themselves are unchanged.
        NotificationCenter.default.post(name: .mobileHostStatusDidChange, object: nil)
    }

    private nonisolated static func iosBundleIdentifier(from params: [String: Any]) -> String? {
        let raw = (params["ios_bundle_identifier"] as? String)
            ?? (params["ios_bundle_id"] as? String)
            ?? (params["iosBundleIdentifier"] as? String)
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private nonisolated static func statusResultIncludesIdentity(
        _ result: MobileHostRPCResult
    ) -> Bool {
        guard case let .ok(payload) = result,
              let object = payload as? [String: Any],
              let deviceID = object["mac_device_id"] as? String else {
            return false
        }
        return !deviceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Binds the reported app namespace to the authenticated transport session
    /// before it enters durable routing state. The Stack route contributes the
    /// verified same-account identity; Iroh contributes its broker-issued peer
    /// tuple. No unauthenticated status probe can manufacture this value.
    private nonisolated static func authenticatedHandshakeIdentity(
        authorization: MobileHostConnectionAuthorizationContext,
        request: MobileHostRPCRequest,
        sessionIdentity: AuthenticatedSessionIdentity
    ) -> String? {
        switch authorization {
        case .stackBearer:
            guard request.auth?.stackAccessToken?.isEmpty == false else {
                return nil
            }
            // Include the auth-session generation so a later sign-in or
            // variant re-pair may replace the target, while repeated status
            // responses within one authenticated session cannot switch it.
            return "stack:\(sessionIdentity.accountID):\(sessionIdentity.generation)"
        case let .irohAdmission(peer):
            let bindingID = peer.bindingID.trimmingCharacters(in: .whitespacesAndNewlines)
            let endpointID = peer.endpointID.endpointID
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !bindingID.isEmpty, !endpointID.isEmpty else { return nil }
            return "iroh:\(bindingID):\(peer.identityGeneration):\(endpointID)"
        }
    }
}
