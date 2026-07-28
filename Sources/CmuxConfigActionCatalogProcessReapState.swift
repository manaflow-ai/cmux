enum CmuxConfigActionCatalogProcessReapState {
    case pending
    case blocking
    case confirmed
    case unconfirmedFailure(CmuxConfigActionCatalogProcessWaitResult)
}
