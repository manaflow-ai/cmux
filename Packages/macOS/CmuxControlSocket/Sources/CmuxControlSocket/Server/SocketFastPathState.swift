public import Foundation
internal import os

/// Per-surface dedupe cache for high-frequency socket telemetry reports
/// (`report_*` shell-activity updates), so repeated identical reports skip
/// the main-actor publish.
///
/// States are compared as raw `String` tokens so the cache stays decoupled
/// from the app's shell-activity enum:
///
/// ```swift
/// let fastPath = SocketFastPathState()
/// if fastPath.shouldPublishShellActivity(
///     workspaceId: workspaceId, panelId: panelId, state: state.rawValue
/// ) {
///     // forward the state change to the main-actor model
/// }
/// ```
public final class SocketFastPathState: Sendable {
    private struct SocketSurfaceKey: Hashable {
        let workspaceId: UUID
        let panelId: UUID
        let terminalLifecycleID: UUID?
    }

    // Lock carve-out: synchronous compare-and-set on the socket telemetry hot
    // path, called from non-async socket worker threads where an actor hop
    // would reorder racing reports.
    private let lastReportedShellStates: OSAllocatedUnfairLock<[SocketSurfaceKey: String]>
    private let maxTrackedShellStates: Int

    /// Creates an empty dedupe cache.
    /// - Parameter maxTrackedShellStates: Entry cap; the cache resets when the
    ///   cap is reached, matching the legacy bound.
    public init(maxTrackedShellStates: Int = 4096) {
        self.lastReportedShellStates = OSAllocatedUnfairLock(initialState: [:])
        self.maxTrackedShellStates = maxTrackedShellStates
    }

    /// Whether a shell-activity report for the surface changed since the last
    /// publish and should be forwarded; see ``SocketFastPathState`` for an
    /// example.
    /// - Parameters:
    ///   - workspaceId: The reporting workspace.
    ///   - panelId: The reporting surface/panel.
    ///   - terminalLifecycleID: The reporting terminal process generation, or
    ///     `nil` for backward-compatible clients.
    ///   - state: The shell-activity state's raw token.
    /// - Returns: `true` when the state differs from the last published value
    ///   for this surface (recording it), `false` for a duplicate.
    public func shouldPublishShellActivity(
        workspaceId: UUID,
        panelId: UUID,
        terminalLifecycleID: UUID? = nil,
        state: String
    ) -> Bool {
        let key = SocketSurfaceKey(
            workspaceId: workspaceId,
            panelId: panelId,
            terminalLifecycleID: terminalLifecycleID
        )
        return lastReportedShellStates.withLock { lastReportedShellStates in
            if lastReportedShellStates[key] == state {
                return false
            }
            if lastReportedShellStates.count >= maxTrackedShellStates {
                lastReportedShellStates.removeAll(keepingCapacity: true)
            }
            lastReportedShellStates[key] = state
            return true
        }
    }

    /// Discards shell-activity dedupe state when a panel lifecycle ends.
    ///
    /// A restored surface may intentionally reuse its previous panel ID. Its
    /// replacement shell must publish its first state even when that state
    /// matches the shell that was closed.
    ///
    /// - Parameter panelId: The panel ID whose entries should be removed from
    ///   every workspace scope.
    public func removeShellActivity(panelId: UUID) {
        lastReportedShellStates.withLock { lastReportedShellStates in
            lastReportedShellStates = lastReportedShellStates.filter {
                $0.key.panelId != panelId
            }
        }
    }
}
