/// The bounded result of applying one structured background-work event.
struct AgentStructuredBackgroundWorkUpdate: Equatable, Sendable {
    let activeWorkCount: Int
    let deferredSettlement: AgentDeferredTurnSettlement?
}
