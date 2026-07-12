internal import CmuxMobileRPC

extension MobileShellComposite {
    /// Whether a transport failure can arrive after the host applied a mutation.
    func workspaceMutationMayHaveApplied(_ error: any Error) -> Bool {
        guard let connectionError = error as? MobileShellConnectionError else { return true }
        switch connectionError {
        case .connectionClosed, .requestTimedOut, .invalidResponse:
            return true
        case .attachTicketExpired, .authorizationFailed, .accountMismatch,
             .insecureManualRoute, .rpcError:
            return false
        }
    }
}
