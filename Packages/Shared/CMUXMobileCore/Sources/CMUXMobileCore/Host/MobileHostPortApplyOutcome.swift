/// Outcome of an explicit "Apply port" request from settings. A pure value so
/// the pre-bind classification is unit-testable without binding a real
/// `NWListener`.
public enum MobileHostPortApplyOutcome: Equatable, Sendable {
    /// The port was accepted; the listener is (or will be) bound to it.
    case applied(Int)
    /// The port is in use by another process; the running listener was left untouched.
    case portInUse
    /// Pairing is off, so the port was saved and will bind when pairing is enabled.
    case savedWhileDisabled
    /// The requested port was outside the valid `1...65535` range.
    case invalid

    /// Pure pre-bind classification for an explicit "Apply port" request. Returns
    /// the outcome for the cases that need no bind attempt, or `nil` when a real
    /// bind must be tried (pairing on, valid port, different from the bound one).
    /// Factored out so the decision is unit-testable without a real `NWListener`.
    ///
    /// - Parameters:
    ///   - enabled: Whether iOS pairing is enabled in settings.
    ///   - currentBoundPort: The port the listener is currently bound to, or `nil`.
    ///   - requestedPort: The port the user asked to apply.
    public static func preBind(
        enabled: Bool,
        currentBoundPort: Int?,
        requestedPort: Int
    ) -> MobileHostPortApplyOutcome? {
        guard (1...65535).contains(requestedPort) else { return .invalid }
        guard enabled else { return .savedWhileDisabled }
        if currentBoundPort == requestedPort { return .applied(requestedPort) }
        return nil
    }
}
