/// The events ``EventInbox`` coalesces: each states the whole current value of one field of one
/// surface, and the store applies it as a plain write, so only the newest in a batch matters.
///
/// `agent-changed` is not one of them: the roster records the transition from the old status to
/// the new one (``AgentRoster/startsPromptedTurn(from:to:)``, ``AgentTimeline/events(from:to:nowMs:)``),
/// so a working -> idle -> working run collapsed to its last status would lose a finished turn and
/// a prompt.
enum CoalesceKey: Hashable {
    case title(SurfaceID)
    case size(SurfaceID)
    case scroll(SurfaceID)
    case presence(SurfaceID)

    init?(_ event: DaemonEvent) {
        switch event {
        case .titleChanged(let surface, _): self = .title(surface)
        case .surfaceResized(let surface, _): self = .size(surface)
        case .scrollChanged(let surface, _, _): self = .scroll(surface)
        case .agentPresenceChanged(let presence): self = .presence(presence.surface)
        default: return nil
        }
    }
}
