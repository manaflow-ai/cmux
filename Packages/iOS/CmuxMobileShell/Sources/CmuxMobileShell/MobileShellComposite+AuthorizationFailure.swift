import CMUXMobileCore
import CmuxMobileRPC
import CmuxMobileSupport
import Foundation

@MainActor
extension MobileShellComposite {
    func disconnectForAuthorizationFailureIfNeeded(_ error: any Error, route: CmxAttachRoute? = nil) -> Bool {
        guard Self.shouldDisconnectForAuthorizationFailure(error) else {
            return false
        }
        let category = MobilePairingFailureCategory.classify(error: error, route: route ?? activeRoute)
        // Not `applyPairingFailure`: this path also sets `connectionRequiresReauth`,
        // uses fallback-if-empty, and gates analytics on `pairingAttemptMethod` so
        // live-connection auth evictions never emit `ios_pairing_failed`.
        connectionError = category.message.isEmpty
            ? L10n.string("mobile.pairing.runtimeUnavailable", defaultValue: "Could not connect to your computer.")
            : category.message
        connectionErrorGuidance = category.guidance
        connectionRequiresReauth = true
        connectionState = .disconnected
        macConnectionStatus = .unavailable
        clearRemoteConnectionContext()
        // Only emits while a pairing attempt is in flight: `recordPairingFailed`
        // no-ops once `pairingAttemptMethod` is nil (cleared on success and by
        // `invalidatePairingAttempt`), so live-connection auth failures that
        // also route through here never emit `ios_pairing_failed`.
        recordPairingFailed(reason: category.analyticsReason, phase: "auth")
        return true
    }

    private static func shouldDisconnectForAuthorizationFailure(_ error: any Error) -> Bool {
        guard let connectionError = error as? MobileShellConnectionError else {
            return false
        }
        switch connectionError {
        case .attachTicketExpired, .authorizationFailed, .accountMismatch, .insecureManualRoute:
            return true
        case let .rpcError(code, message):
            let normalizedCode = code?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let normalizedCode,
               ["unauthorized", "forbidden", "invalid_token", "token_expired", "expired_token", "auth_required"].contains(normalizedCode) {
                return true
            }
            let normalizedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return normalizedMessage.contains("unauthorized")
                || normalizedMessage.contains("forbidden")
                || normalizedMessage.contains("invalid token")
                || normalizedMessage.contains("expired token")
                || normalizedMessage.contains("token expired")
        case .invalidResponse, .connectionClosed, .requestTimedOut:
            return false
        }
    }
}
