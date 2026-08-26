import CmuxWorkspaces

/// One bounded context-pressure payload awaiting main-actor delivery.
struct TerminalContextPressureForward: Sendable {
    let generation: UInt64
    let monitoringGeneration: UInt64
    let events: [AgentContextPressureEvent]
}
