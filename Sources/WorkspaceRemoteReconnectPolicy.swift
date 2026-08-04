import Foundation
import CmuxCore

/// Pure decision logic for the SSH remote workspace auto-reconnect loop
/// (https://github.com/manaflow-ai/cmux/issues/5734).
///
/// While the host stays reachable the loop keeps its existing exponential
/// backoff behavior. Once consecutive reachability probes keep failing, the
/// loop should suspend instead of retrying indefinitely, leaving the user in
/// control of when reconnection happens.
enum WorkspaceRemoteReconnectPolicy {
    enum Decision: Equatable, Sendable {
        /// Keep the scheduled backoff retry armed.
        case scheduleRetry
        /// Halt the automatic reconnect loop and wait for a manual reconnect.
        case suspend
    }

    struct Evaluation: Equatable, Sendable {
        /// Consecutive failed probes after accounting for the latest outcome.
        let consecutiveUnreachableProbes: Int
        let decision: Decision
    }

    /// Number of consecutive unreachable probes after which the automatic
    /// reconnect loop suspends. Sized to absorb short network transitions
    /// (sleep/wake, wifi handoff) without retrying indefinitely against a
    /// host that cannot be reached.
    static let maxConsecutiveUnreachableProbes = 3

    static func evaluate(
        outcome: WorkspaceRemoteHostProbeOutcome,
        previousConsecutiveUnreachableProbes: Int
    ) -> Evaluation {
        switch outcome {
        case .reachable, .indeterminate:
            return Evaluation(consecutiveUnreachableProbes: 0, decision: .scheduleRetry)
        case .unreachable:
            let streak = previousConsecutiveUnreachableProbes + 1
            return Evaluation(
                consecutiveUnreachableProbes: streak,
                decision: streak >= Self.maxConsecutiveUnreachableProbes ? .suspend : .scheduleRetry
            )
        }
    }
}

enum CloudTerminalReconnectOverlayPolicy {
    struct Presentation: Equatable, Sendable {
        let title: String
        let detail: String
        let showsProgress: Bool
        let showsReconnectButton: Bool
    }

    static func presentation(
        isManagedCloudWorkspace: Bool,
        isRemoteTerminalSurface: Bool,
        connectionState: WorkspaceRemoteConnectionState,
        detail: String?
    ) -> Presentation? {
        guard isManagedCloudWorkspace, isRemoteTerminalSurface else { return nil }

        let trimmedDetail = detail?.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayDetail = trimmedDetail?.isEmpty == false ? trimmedDetail : nil
        switch connectionState {
        case .connected:
            return nil
        case .connecting, .reconnecting:
            return Presentation(
                title: String(localized: "cloud.overlay.reconnecting.title", defaultValue: "Reconnecting Cloud session"),
                detail: displayDetail
                    ?? String(
                        localized: "cloud.overlay.reconnecting.detail",
                        defaultValue: "Waiting for a secure terminal endpoint."
                    ),
                showsProgress: true,
                showsReconnectButton: false
            )
        case .disconnected:
            return Presentation(
                title: String(localized: "cloud.overlay.disconnected.title", defaultValue: "Cloud session disconnected"),
                detail: displayDetail
                    ?? String(
                        localized: "cloud.overlay.disconnected.detail",
                        defaultValue: "The terminal session is offline. Reconnect when you are ready."
                    ),
                showsProgress: false,
                showsReconnectButton: true
            )
        case .suspended:
            return Presentation(
                title: String(localized: "cloud.overlay.suspended.title", defaultValue: "Cloud session unavailable"),
                detail: displayDetail
                    ?? String(
                        localized: "cloud.overlay.suspended.detail",
                        defaultValue: "Automatic reconnect paused. Reconnect to try again."
                    ),
                showsProgress: false,
                showsReconnectButton: true
            )
        case .error:
            return Presentation(
                title: String(localized: "cloud.overlay.error.title", defaultValue: "Cloud session unavailable"),
                detail: displayDetail
                    ?? String(
                        localized: "cloud.overlay.error.detail",
                        defaultValue: "The secure terminal endpoint is unavailable."
                    ),
                showsProgress: false,
                showsReconnectButton: true
            )
        }
    }
}
