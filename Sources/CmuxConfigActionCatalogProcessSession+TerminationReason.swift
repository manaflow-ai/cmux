extension CmuxConfigActionCatalogProcessSession {
    enum TerminationReason {
        case cancelled
        case timedOut
        case outputOverflow
        case pipeFailure
    }
}
