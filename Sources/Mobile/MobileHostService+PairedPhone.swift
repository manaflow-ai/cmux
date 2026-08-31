import Foundation

@MainActor
extension MobileHostService {
    /// Returns the bundle selected by the most recent authenticated pairing for
    /// `accountID`. Missing identity is deliberately fail-closed.
    func pairedPhoneBundleIdentifier(accountID: String?) -> String? {
        pairedPhoneStore.targetBundleIdentifier(accountID: accountID)
    }

    /// Persists phone identity only after an authenticated host-status response
    /// proves the connection is usable. Public status probes remain identity-free
    /// and cannot influence push or backup routing.
    func recordPairedPhoneIfNeeded(
        request: MobileHostRPCRequest,
        result: MobileHostRPCResult,
        authorization: MobileHostConnectionAuthorizationContext
    ) async {
        guard let clientID = Self.clientID(from: request.params),
              let bundleIdentifier = Self.iosBundleIdentifier(from: request.params),
              Self.statusResultIncludesIdentity(result),
              let accountID = await currentAuthenticatedLocalUserID() else {
            return
        }
        guard let handshakeIdentity = Self.authenticatedHandshakeIdentity(
            authorization: authorization,
            request: request,
            accountID: accountID
        ) else {
            return
        }
        let previousTarget = pairedPhoneStore.targetBundleIdentifier(accountID: accountID)
        guard pairedPhoneStore.record(
            clientID: clientID,
            bundleIdentifier: bundleIdentifier,
            accountID: accountID,
            handshakeIdentity: handshakeIdentity
        ) else { return }
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
        accountID: String
    ) -> String? {
        switch authorization {
        case .stackBearer:
            guard request.auth?.stackAccessToken?.isEmpty == false else {
                return nil
            }
            return "stack:\(accountID)"
        case let .irohAdmission(peer):
            let bindingID = peer.bindingID.trimmingCharacters(in: .whitespacesAndNewlines)
            let endpointID = peer.endpointID.endpointID
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !bindingID.isEmpty, !endpointID.isEmpty else { return nil }
            return "iroh:\(bindingID):\(peer.identityGeneration):\(endpointID)"
        }
    }
}
