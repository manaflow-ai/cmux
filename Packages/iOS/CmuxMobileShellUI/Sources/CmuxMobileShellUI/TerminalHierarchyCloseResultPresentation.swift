import CmuxMobileShell

enum TerminalHierarchyCloseResultPresentation: Equatable {
    case closed
    case confirmationRequired
    case appliedNeedsRefresh
    case resultUnknownNeedsRefresh
    case resultUnknownRefreshed
    case protected
    case failed

    init(_ result: Result<Void, MobileWorkspaceMutationFailure>) {
        switch result {
        case .success:
            self = .closed
        case .failure(.confirmationRequired):
            self = .confirmationRequired
        case .failure(.appliedNeedsRefresh):
            self = .appliedNeedsRefresh
        case .failure(.resultUnknownNeedsRefresh):
            self = .resultUnknownNeedsRefresh
        case .failure(.resultUnknownRefreshed):
            self = .resultUnknownRefreshed
        case .failure(.protected):
            self = .protected
        case .failure:
            self = .failed
        }
    }
}

enum TerminalHierarchyCreationResultPresentation: Equatable {
    case created
    case appliedNeedsRefresh
    case resultUnknownNeedsRefresh
    case resultUnknownRefreshed
    case failed

    init(_ result: Result<Void, MobileWorkspaceMutationFailure>) {
        switch result {
        case .success:
            self = .created
        case .failure(.appliedNeedsRefresh):
            self = .appliedNeedsRefresh
        case .failure(.resultUnknownNeedsRefresh):
            self = .resultUnknownNeedsRefresh
        case .failure(.resultUnknownRefreshed):
            self = .resultUnknownRefreshed
        case .failure:
            self = .failed
        }
    }
}
