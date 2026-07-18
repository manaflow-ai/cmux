/// Exact command-line routing for destructive terminal-backend maintenance.
public struct BackendServiceMaintenanceInvocation: Equatable, Sendable {
    /// The only argument accepted for a read-only registration-status query.
    public static let statusArgument = "--terminal-backend-service-status"

    /// The only argument accepted for destructive service unregistration.
    public static let unregisterArgument = "--unregister-terminal-backend-service"

    /// The requested maintenance operation.
    public let operation: BackendServiceMaintenanceOperation

    /// Parses an exact executable-plus-operation argument vector.
    ///
    /// Extra arguments are rejected so an unrelated app launch can never
    /// accidentally enter the destructive unregistration path.
    ///
    /// - Parameter arguments: The complete process argument vector, including argv zero.
    public init?(arguments: [String]) {
        guard arguments.count == 2 else { return nil }
        switch arguments[1] {
        case Self.statusArgument:
            operation = .status
        case Self.unregisterArgument:
            operation = .unregister
        default:
            return nil
        }
    }
}
