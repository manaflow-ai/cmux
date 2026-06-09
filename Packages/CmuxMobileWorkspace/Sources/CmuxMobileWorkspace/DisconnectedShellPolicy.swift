/// Pure classifier mapping the mobile-shell store's connection-related state to
/// the ``DisconnectedShellState`` the disconnected screen renders.
///
/// Kept as a pure function (no store, no UIKit) so the never-paired vs
/// offline vs reconnecting decision is unit-testable without standing up the
/// composite store, mirroring ``MobileRootAuthGate``.
public struct DisconnectedShellPolicy {
    private init() {}

    /// Classify the disconnected screen's state from the store's signals.
    ///
    /// The disconnected screen is only mounted while `connectionState` is not
    /// `.connected`, so this assumes a non-connected link and does not branch on
    /// the connection state itself.
    ///
    /// - Parameters:
    ///   - hasKnownPairedMac: The persisted hint that this device has paired a Mac
    ///     before. `true` means there is a Mac to reconnect to; `false` means the
    ///     device has never paired (or the last Mac was definitively forgotten).
    ///   - isReconnectingStoredMac: Whether a stored Mac is actively mid-reconnect
    ///     on launch.
    ///   - isRecoveringConnection: Whether a user-initiated or network-triggered
    ///     recovery attempt is actively in flight.
    /// - Returns: ``DisconnectedShellState/reconnecting`` while an attempt is in
    ///   flight; otherwise ``DisconnectedShellState/offline`` when a Mac is known,
    ///   or ``DisconnectedShellState/neverPaired`` when none is.
    public static func state(
        hasKnownPairedMac: Bool,
        isReconnectingStoredMac: Bool,
        isRecoveringConnection: Bool
    ) -> DisconnectedShellState {
        // An in-flight attempt always wins: show the bounded reconnect indicator
        // rather than an offline message that contradicts the live attempt.
        if isReconnectingStoredMac || isRecoveringConnection {
            return .reconnecting
        }
        return hasKnownPairedMac ? .offline : .neverPaired
    }
}
