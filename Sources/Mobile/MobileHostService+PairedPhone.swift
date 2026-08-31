import Foundation

@MainActor
extension MobileHostService {
    /// Returns the bundle selected by the most recent completed pairing for
    /// `accountID`, falling back to the lane-derived compatibility target when
    /// no handshake record exists.
    func pairedPhoneBundleIdentifier(accountID: String?) -> String? {
        pairedPhoneStore.targetBundleIdentifier(accountID: accountID)
    }

    /// Persists phone identity only after an authenticated host-status response
    /// proves the connection is usable. Public status probes remain identity-free
    /// and cannot influence push or backup routing.
    func recordPairedPhoneIfNeeded(
        request: MobileHostRPCRequest,
        result: MobileHostRPCResult,
        transportAuthenticated: Bool
    ) async {
        guard let clientID = Self.clientID(from: request.params),
              let bundleIdentifier = Self.iosBundleIdentifier(from: request.params),
              (transportAuthenticated || request.auth?.stackAccessToken != nil),
              Self.statusResultIncludesIdentity(result),
              let accountID = await currentAuthenticatedLocalUserID() else {
            return
        }
        let previousTarget = pairedPhoneStore.targetBundleIdentifier(accountID: accountID)
        guard pairedPhoneStore.record(
            clientID: clientID,
            bundleIdentifier: bundleIdentifier,
            accountID: accountID
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
}
