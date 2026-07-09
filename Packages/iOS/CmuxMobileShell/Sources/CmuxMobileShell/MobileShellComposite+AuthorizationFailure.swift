import CMUXMobileCore
import CmuxMobileRPC
import Foundation

@MainActor
extension MobileShellComposite {
    func disconnectForAuthorizationFailureIfNeeded(
        _ error: any Error,
        route: CmxAttachRoute? = nil,
        preservingActiveConnection: Bool = false
    ) -> Bool {
        guard shouldDisconnectForAuthorizationFailure(error) else {
            return false
        }
        let category = MobilePairingFailureCategory.classify(error: error, route: route ?? activeRoute)
        applyAuthorizationFailure(category, preservingActiveConnection: preservingActiveConnection)
        return true
    }

    private func shouldDisconnectForAuthorizationFailure(_ error: any Error) -> Bool {
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
