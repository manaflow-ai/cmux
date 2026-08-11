enum BackendOnlyRendererConfigRefreshError: Error, Equatable, Sendable {
    case inconsistentRevision
    case staleReceipt
}
