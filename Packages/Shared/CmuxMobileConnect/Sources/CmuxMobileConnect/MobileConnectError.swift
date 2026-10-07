public import CmuxLink

public enum MobileConnectError: Error, Sendable, Hashable {
    /// The Mac's plan leaves this carrier out of the race (a direct route
    /// can work, or none is configured).
    case excludedByPlan(CarrierKind)
}
