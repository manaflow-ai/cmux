/// The events ``EventInbox`` coalesces: each states the whole current value of one field of one
/// surface, so only the newest in a batch matters.
enum CoalesceKey: Hashable {
    case title(SurfaceID)
    case size(SurfaceID)
    case scroll(SurfaceID)
    case agent(SurfaceID)
    case presence(SurfaceID)

    init?(_ event: DaemonEvent) {
        switch event {
        case .titleChanged(let surface, _): self = .title(surface)
        case .surfaceResized(let surface, _): self = .size(surface)
        case .scrollChanged(let surface, _, _): self = .scroll(surface)
        case .agentChanged(let status): self = .agent(status.surface)
        case .agentPresenceChanged(let presence): self = .presence(presence.surface)
        default: return nil
        }
    }
}
