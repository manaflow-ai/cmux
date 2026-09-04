import CmuxMobileShellModel

/// Decides whether a workspace's absence from a freshly derived list is
/// authoritative — the workspace genuinely ceased to exist (deleted, closed,
/// or its Mac was unpaired/hidden) — or a transient hole opened by a degraded
/// connection (drop, redial, secondary-snapshot purge on foreground death).
///
/// Selection and navigation may retarget or pop the mounted detail only on an
/// authoritative absence. A transient absence keeps the selection so the
/// detail's last-known snapshot stays mounted until the connection resolves;
/// the next healthy list then either restores the row or confirms the
/// deletion, which retargets normally.
enum WorkspaceAbsenceAuthority {
    /// - Parameters:
    ///   - hasLastKnownRow: Whether the caller still holds the vanished
    ///     workspace's last-known row. Without one the owner cannot be
    ///     attributed, so only the foreground's health can gate the decision.
    ///   - rowIsForegroundServed: Whether that row is served by the
    ///     foreground RPC connection (device and build tag match the live or
    ///     recovering pairing).
    ///   - foregroundIsHealthy: Live foreground authority — connected with no
    ///     recovery in flight and no failed recovery.
    ///   - ownerStatus: The owning Mac's per-entry status, or `nil` when its
    ///     entry is gone entirely. A missing entry is an authoritative
    ///     removal (unpair/hide) when the foreground is healthy, and the
    ///     foreground-death purge of secondary snapshots otherwise.
    static func absenceIsAuthoritative(
        hasLastKnownRow: Bool,
        rowIsForegroundServed: Bool,
        foregroundIsHealthy: Bool,
        ownerStatus: MobileMacConnectionStatus?
    ) -> Bool {
        guard hasLastKnownRow, !rowIsForegroundServed else {
            return foregroundIsHealthy
        }
        guard let ownerStatus else {
            return foregroundIsHealthy
        }
        return ownerStatus == .connected
    }
}
