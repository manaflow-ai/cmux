/// The result of an explicit persistent-backend unregistration request.
public enum BackendServiceUnregisterResult: Equatable, Sendable {
    /// The service was enabled or pending approval and is now unregistered.
    case unregistered

    /// The service was already unregistered.
    case alreadyUnregistered

    /// ServiceManagement could not resolve the launch-agent definition.
    case serviceNotFound
}
