import Foundation

/// What ``MobileHostService.syncToSettings()`` should do to reconcile the live
/// listener with the current settings.
///
/// A pure value so the restart-on-port-change logic is unit-testable without a
/// real `NWListener`. The `@MainActor` listener-state code lives app-side and
/// forwards to ``decide(enabled:listenerRunning:desiredPort:appliedPort:)``,
/// which carries no listener or main-actor state.
public enum MobileHostSyncDecision: Equatable, Sendable {
    /// The live listener already matches settings; do nothing.
    case noop
    /// Pairing is enabled but no listener is bound; start one.
    case start
    /// Pairing is disabled but a listener is bound; tear it down.
    case stop
    /// A listener is bound but on the wrong port; rebind on the desired port.
    case restart

    /// Pure reconciliation between the desired settings and the live listener
    /// state. Factored out so the restart-on-port-change decision is unit
    /// testable without binding a real `NWListener`.
    ///
    /// - Parameters:
    ///   - enabled: Whether the iOS pairing host is enabled in settings.
    ///   - listenerRunning: Whether a listener is currently bound.
    ///   - desiredPort: The preferred port from settings.
    ///   - appliedPort: The preferred port the running listener targeted, or
    ///     `nil` when stopped.
    /// - Returns: The action the settings sync should take.
    public static func decide(
        enabled: Bool,
        listenerRunning: Bool,
        desiredPort: Int,
        appliedPort: Int?
    ) -> MobileHostSyncDecision {
        guard enabled else { return listenerRunning ? .stop : .noop }
        guard listenerRunning else { return .start }
        if appliedPort != desiredPort { return .restart }
        return .noop
    }
}
