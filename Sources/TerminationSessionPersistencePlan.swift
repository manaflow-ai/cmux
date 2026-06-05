struct TerminationSessionPersistencePlan: Equatable, Sendable {
    let saveSnapshot: Bool
    let includeScrollback: Bool
    let flushClosedItemHistory: Bool
}
