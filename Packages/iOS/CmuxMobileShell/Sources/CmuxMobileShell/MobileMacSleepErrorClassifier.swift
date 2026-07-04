internal import CmuxMobileRPC

struct MobileMacSleepErrorClassifier {
    func result(forSendError error: any Error) -> MobileMacSleepResult {
        guard let connectionError = error as? MobileShellConnectionError else {
            return .failed
        }
        switch connectionError {
        case .rpcError:
            return .refused
        case .invalidResponse,
             .connectionClosed,
             .requestTimedOut,
             .insecureManualRoute,
             .attachTicketExpired,
             .authorizationFailed,
             .accountMismatch:
            return .failed
        }
    }
}
