/// Decides when the "Reconnected to your Mac." toast may present.
///
/// A pure state machine over transport-state edges so the decision never
/// depends on view lifecycle: SwiftUI re-fires `onChange(initial: true)`
/// actions with `previous == current` every time the observing view
/// remounts (returning to a tab remounts its content), and a remount is
/// not a reconnect. Feed the gate every observed edge, including those
/// synthetic equal-value edges; it returns true only for a genuine
/// disconnected → connected transition after the session has already held
/// a connection (the expected first attach stays silent).
public struct MobileReconnectedToastGate: Equatable, Sendable {
    /// True once this gate has observed a live connection.
    private var hasHeldConnection = false

    public init() {}

    public mutating func shouldToast(
        from previous: MobileConnectionState,
        to current: MobileConnectionState
    ) -> Bool {
        guard current == .connected else { return false }
        defer { hasHeldConnection = true }
        return hasHeldConnection
    }
}
