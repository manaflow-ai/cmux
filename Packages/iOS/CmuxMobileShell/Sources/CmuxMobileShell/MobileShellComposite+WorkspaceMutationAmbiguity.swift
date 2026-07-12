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

    func unreconciledWorkspaceMutationFailure(
        _ error: any Error,
        hostDisplayName: String?
    ) -> MobileWorkspaceMutationFailure {
        if workspaceMutationMayHaveApplied(error) {
            return .resultUnknownNeedsRefresh(hostDisplayName: hostDisplayName)
        }
        return workspaceMutationFailure(error, hostDisplayName: hostDisplayName)
    }
}
