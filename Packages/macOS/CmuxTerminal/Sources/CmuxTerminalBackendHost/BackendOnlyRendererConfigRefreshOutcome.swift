enum BackendOnlyRendererConfigRefreshOutcome: Equatable, Sendable {
    case ignored
    case refreshed(BackendOnlyRendererConfigIdentity)

    var identity: BackendOnlyRendererConfigIdentity? {
        switch self {
        case .ignored:
            nil
        case let .refreshed(identity):
            identity
        }
    }
}
