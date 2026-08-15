import CmuxWorkspaces
import Foundation
import SwiftUI

/// Presentation-level liveness for a Vault session row: whether the agent
/// process behind the indexed transcript is currently running, and if so
/// whether it has shown recent activity.
enum VaultSessionLiveStatus: Equatable, Sendable {
    case live
    case idle
    case exited

    /// Activity window separating `.live` from `.idle` for a running process.
    nonisolated static let liveActivityWindow: TimeInterval = 5 * 60

    /// Pure classification. `isProcessRunning` comes from the live agent
    /// index; `lastActivity` is the transcript's modification date.
    nonisolated static func derive(
        isProcessRunning: Bool,
        lastActivity: Date,
        now: Date
    ) -> VaultSessionLiveStatus {
        guard isProcessRunning else { return .exited }
        return now.timeIntervalSince(lastActivity) <= liveActivityWindow ? .live : .idle
    }

    var label: String {
        switch self {
        case .live:
            return String(localized: "sessionIndex.status.live", defaultValue: "Live")
        case .idle:
            return String(localized: "sessionIndex.status.idle", defaultValue: "Idle")
        case .exited:
            return String(localized: "sessionIndex.status.exited", defaultValue: "Ended")
        }
    }

    var dotColor: Color {
        switch self {
        case .live: return .green
        case .idle: return .orange
        case .exited: return Color.secondary.opacity(0.4)
        }
    }
}

/// Join keys between disk-indexed `SessionEntry` values and the process-side
/// `RestorableAgentSessionIndex`, expressed as `<kind rawValue>:<canonical id>`.
enum VaultLiveSessionKeys {
    nonisolated static func key(kind: String, sessionID: String) -> String {
        let canonical = ManagedAgentSessionIdentity.canonicalSessionID(
            kind: kind,
            sessionID: sessionID
        )
        return kind + ":" + canonical
    }

    nonisolated static func key(for entry: SessionEntry) -> String {
        key(kind: entry.agent.rawValue, sessionID: entry.sessionId)
    }

    /// Keys of every session the live index currently observes as running.
    nonisolated static func runningKeys(in index: RestorableAgentSessionIndex?) -> Set<String> {
        guard let index else { return [] }
        var keys: Set<String> = []
        for (_, entry) in index.forkValidationEntries() where entry.processLiveness == .running {
            keys.insert(
                key(
                    kind: entry.snapshot.kind.rawValue,
                    sessionID: entry.snapshot.sessionId
                )
            )
        }
        return keys
    }
}
