/// Link quality reported by a carrier.
public enum LinkHealth: Sendable, Hashable {
    case good
    case degraded(DegradedReason)
}
