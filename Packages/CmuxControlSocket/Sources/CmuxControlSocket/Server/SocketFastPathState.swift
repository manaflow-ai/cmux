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
///     workspaceId: workspaceId, panelId: panelId, state: state.rawValue, sequence: sequence
/// ) {
///     // forward the state change to the main-actor model
/// }
/// ```
public final class SocketFastPathState: Sendable {
    private struct SocketSurfaceKey: Hashable {
        let workspaceId: UUID
        let panelId: UUID
    }

    private struct ReportedShellActivity {
        var state: String
        var sequence: UInt64?
    }

    // Lock carve-out: synchronous compare-and-set on the socket telemetry hot
    // path, called from non-async socket worker threads where an actor hop
    // would reorder racing reports.
    private let lastReportedShellStates: OSAllocatedUnfairLock<[SocketSurfaceKey: ReportedShellActivity]>
    private let maxTrackedShellStates: Int

    /// Creates an empty dedupe cache.
    /// - Parameter maxTrackedShellStates: Entry cap; the cache resets when the
    ///   cap is reached, matching the legacy bound.
    public init(maxTrackedShellStates: Int = 4096) {
        self.lastReportedShellStates = OSAllocatedUnfairLock(initialState: [:])
        self.maxTrackedShellStates = maxTrackedShellStates
    }

    /// Whether a shell-activity report for the surface changed since the last
    /// publish, is not stale, and should be forwarded; see
    /// ``SocketFastPathState`` for an example.
    /// - Parameters:
    ///   - workspaceId: The reporting workspace.
    ///   - panelId: The reporting surface/panel.
    ///   - state: The shell-activity state's raw token.
    ///   - sequence: Optional monotonic shell report sequence for suppressing
    ///     late reports from older prompt hooks.
    /// - Returns: `true` when the report should publish and be recorded,
    ///   `false` for a duplicate or stale sequenced report.
    public func shouldPublishShellActivity(
        workspaceId: UUID,
        panelId: UUID,
        state: String,
        sequence: UInt64? = nil
    ) -> Bool {
        let key = SocketSurfaceKey(workspaceId: workspaceId, panelId: panelId)
        return lastReportedShellStates.withLock { lastReportedShellStates in
            if let current = lastReportedShellStates[key] {
                if let sequence, let currentSequence = current.sequence {
                    guard sequence > currentSequence else {
                        return false
                    }
                } else if current.state == state {
                    return false
                }
            }
            if lastReportedShellStates.count >= maxTrackedShellStates {
                lastReportedShellStates.removeAll(keepingCapacity: true)
            }
            lastReportedShellStates[key] = ReportedShellActivity(
                state: state,
                sequence: sequence ?? lastReportedShellStates[key]?.sequence
            )
            return true
        }
    }
}
