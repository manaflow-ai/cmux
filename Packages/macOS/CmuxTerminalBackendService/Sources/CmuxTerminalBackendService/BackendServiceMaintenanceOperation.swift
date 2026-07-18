/// A pre-AppKit maintenance operation supported by the cmux app executable.
public enum BackendServiceMaintenanceOperation: Equatable, Sendable {
    /// Reports whether the app-bundled service is registered with macOS.
    case status

    /// Unregisters the service and terminates the PTYs it owns.
    case unregister
}
