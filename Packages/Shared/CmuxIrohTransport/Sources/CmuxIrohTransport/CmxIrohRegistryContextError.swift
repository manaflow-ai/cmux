/// Authenticated discovery and pair-grant resolution failures.
public enum CmxIrohRegistryContextError: Error, Equatable, Sendable {
    case unsupportedRoute
    case incompatibleContract
    case relayFleetMismatch
    case localBindingUnavailable
    case targetBindingUnavailable
    case targetDeviceMismatch
    case targetNotPairable
    case invalidGrantExpiry
    case dialPlanUnavailable
}
