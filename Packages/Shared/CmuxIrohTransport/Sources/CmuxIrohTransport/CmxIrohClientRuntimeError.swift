/// Fail-closed iOS Iroh runtime errors.
public enum CmxIrohClientRuntimeError: Error, Equatable, Sendable {
    /// Activation was requested while this runtime already owns an endpoint.
    case alreadyActive

    /// A lifecycle operation requires an active endpoint.
    case inactive

    /// Registration or discovery substituted any local binding field.
    case invalidLocalBinding

    /// Discovery omitted the exact binding returned by registration.
    case localBindingMissingFromDiscovery

    /// Broker policy named a relay fleet different from the app allowlist.
    case relayFleetMismatch

    /// Broker and app disagree on the route-contract version.
    case routeContractMismatch

    /// A later lifecycle generation superseded the current operation.
    case superseded
}
