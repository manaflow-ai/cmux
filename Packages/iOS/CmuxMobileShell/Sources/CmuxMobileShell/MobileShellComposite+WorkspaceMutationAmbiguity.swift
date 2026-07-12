internal import CmuxMobileRPC
internal import Foundation

enum MobileWorkspaceMutationErrorDisposition: Equatable, Sendable {
    /// The host may have applied the request before the response was lost.
    case ambiguous
    /// The host rejected the request without changing authoritative state.
    case immediateRejection
    /// The rejection proves the local row may be stale and needs one refresh.
    case definiteDivergence
}

extension MobileShellComposite {
    func workspaceMutationErrorDisposition(
        _ error: any Error
    ) -> MobileWorkspaceMutationErrorDisposition {
        guard let connectionError = error as? MobileShellConnectionError else { return .ambiguous }
        switch connectionError {
        case .connectionClosed, .requestTimedOut, .invalidResponse:
            return .ambiguous
        case .attachTicketExpired, .authorizationFailed, .accountMismatch, .insecureManualRoute:
            return .immediateRejection
        case let .rpcError(code, _):
            let normalizedCode = code?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let immediateCodes: Set<String> = [
                "confirmation_required", "protected", "unauthorized", "forbidden",
                "invalid_token", "token_expired", "expired_token", "auth_required",
                "account_mismatch", "invalid_params", "invalid_request", "unsupported",
                "not_supported", "unimplemented", "method_not_found", "unavailable",
            ]
            return normalizedCode.map(immediateCodes.contains) == true
                ? .immediateRejection
                : .definiteDivergence
        }
    }

    func unreconciledWorkspaceMutationFailure(
        _ error: any Error,
        hostDisplayName: String?
    ) -> MobileWorkspaceMutationFailure {
        .resultUnknownNeedsRefresh(hostDisplayName: hostDisplayName)
    }

    func reconciledWorkspaceMutationFailure(
        _ error: any Error,
        hostDisplayName: String?
    ) -> MobileWorkspaceMutationFailure {
        .resultUnknownRefreshed(hostDisplayName: hostDisplayName)
    }
}
