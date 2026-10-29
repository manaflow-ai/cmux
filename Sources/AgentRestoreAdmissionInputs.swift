import Foundation
import os

struct AgentRestoreAdmissionInputs: Sendable {
    let workspaceID: UUID
    let surfaceID: UUID
    let kind: String
    let sessionID: String
    let recordSessionID: String
    let codexHome: String?
    let waitForChange: Bool
    let launchLeasePending: Bool
}

/// Remembers when each restore operation first asked for admission.
///
/// The CLI repeats `agent.restore.admit` (with `wait_for_change`) while the
/// app answers `recovering`. Each retry accepts any ownership scan that began
/// after the operation's first request: that scan read every hook record
/// written before the restore asked. Anchoring each retry to its own arrival
/// instead meant a process census longer than one request's deadline could
/// never satisfy any retry, and restored tabs waited forever (#20186).
final class AgentRestoreAdmissionFreshnessAnchors: Sendable {
    static let shared = AgentRestoreAdmissionFreshnessAnchors()

    /// An operation older than this has ended or been abandoned by its CLI.
    private static let retentionNanoseconds: UInt64 = 10 * 60 * 1_000_000_000

    private let anchors = OSAllocatedUnfairLock<[String: UInt64]>(initialState: [:])

    /// Returns the uptime the operation's ownership scan must start after.
    ///
    /// - Parameters:
    ///   - inputs: The admission request.
    ///   - now: The current uptime, injectable for tests.
    /// - Returns: The first request's uptime for a retry, otherwise `now`.
    func anchor(
        for inputs: AgentRestoreAdmissionInputs,
        now: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) -> UInt64 {
        let key = Self.key(for: inputs)
        return anchors.withLock { anchors in
            anchors = anchors.filter { now &- $0.value < Self.retentionNanoseconds }
            if inputs.waitForChange, let anchor = anchors[key] {
                return anchor
            }
            anchors[key] = now
            return now
        }
    }

    /// Forgets an operation that reached a terminal decision.
    func finish(_ inputs: AgentRestoreAdmissionInputs) {
        let key = Self.key(for: inputs)
        _ = anchors.withLock { $0.removeValue(forKey: key) }
    }

    private static func key(for inputs: AgentRestoreAdmissionInputs) -> String {
        [inputs.kind, inputs.sessionID, inputs.surfaceID.uuidString].joined(separator: "\u{1F}")
    }
}
