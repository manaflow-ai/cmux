enum RemoteCreateResponseOutcome: Equatable, Sendable {
    case appliedScopedResponse
    case reconciledAuthoritativeList
    case reconciliationRequired
    case invalidated
}
