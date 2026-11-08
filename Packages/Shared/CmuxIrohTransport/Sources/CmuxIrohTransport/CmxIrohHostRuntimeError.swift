/// Fail-closed host composition errors.
public enum CmxIrohHostRuntimeError: Error, Equatable, Sendable {
    case alreadyActive
    case inactive
    case invalidLocalBinding
    case localBindingMissingFromDiscovery
    case relayFleetMismatch
    case routeContractMismatch
    case superseded
}
