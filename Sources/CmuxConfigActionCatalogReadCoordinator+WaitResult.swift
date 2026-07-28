extension CmuxConfigActionCatalogReadCoordinator {
    enum WaitResult: Sendable {
        case source(CmuxConfigActionCatalogSource)
        case retry
        case unavailable
        case cancelled
    }
}
