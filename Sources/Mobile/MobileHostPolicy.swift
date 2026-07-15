import Foundation

/// What ``MobileHostService/syncToSettings()`` should do to reconcile
/// the live listener with the current settings. A pure value so the
/// restart-on-port-change logic is unit-testable without a real listener.
enum MobileHostSyncDecision: Equatable {
    case noop
    case start
    case stop
    case restart
}

/// Outcome of an explicit "Apply port" request from settings. A pure value so
/// the port-apply policy stays unit-testable without binding a real listener.
enum MobileHostPortApplyOutcome: Equatable {
    /// The port was accepted; the listener is (or will be) bound to it.
    case applied(Int)
    /// The port is in use by another process; the running listener was left untouched.
    case portInUse
    /// Pairing is off, so the port was saved and will bind when pairing is enabled.
    case savedWhileDisabled
    /// The requested port was outside the valid `1...65535` range.
    case invalid
}
