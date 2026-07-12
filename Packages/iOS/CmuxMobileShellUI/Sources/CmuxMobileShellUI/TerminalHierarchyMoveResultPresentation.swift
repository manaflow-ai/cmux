enum TerminalHierarchyMoveResultPresentation: Equatable {
    case unavailable
    case reordered
    case appliedNeedsRefresh
    case resultUnknownNeedsRefresh
    case resultUnknownRefreshed
    case protected
    case failed

    init(_ outcome: TerminalHierarchyMoveActionOutcome) {
        switch outcome {
        case .unavailable:
            self = .unavailable
        case .completed(.success):
            self = .reordered
        case .completed(.failure(.appliedNeedsRefresh)):
            self = .appliedNeedsRefresh
        case .completed(.failure(.resultUnknownNeedsRefresh)):
            self = .resultUnknownNeedsRefresh
        case .completed(.failure(.resultUnknownRefreshed)):
            self = .resultUnknownRefreshed
        case .completed(.failure(.protected)):
            self = .protected
        case .completed(.failure):
            self = .failed
        }
    }
}
