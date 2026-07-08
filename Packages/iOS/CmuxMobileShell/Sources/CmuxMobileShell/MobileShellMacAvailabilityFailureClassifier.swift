internal import CmuxMobileRPC
internal import CmuxMobileTransport

struct MobileShellMacAvailabilityFailureClassifier {
    func isAvailabilityFailure(_ error: any Error) -> Bool {
        if error is CmxNetworkByteTransportError {
            return true
        }
        guard let shellError = error as? MobileShellConnectionError else {
            return false
        }
        switch shellError {
        case .connectionClosed, .requestTimedOut:
            return true
        case .invalidResponse, .insecureManualRoute, .attachTicketExpired, .authorizationFailed, .accountMismatch, .rpcError:
            // .accountMismatch means the Mac is reachable but signed in to a
            // different account; that is an auth problem, not a Mac-availability one.
            return false
        }
    }
}
