import CmuxIrohTransport
import Foundation
import os

/// Relay lines for the `iroh_diag` socket verb.
///
/// Relay URLs are deliberately kept out of `DiagnosticLog` and its report,
/// which stay privacy-safe for Settings exports; only the local debug socket
/// prints them, from the mirror below.
extension MobileHostIrohRuntime {
    /// The relay policy fields the `iroh_diag` socket verb reports.
    struct RelayDiagState: Equatable, Sendable {
        let source: CmxIrohRelayPolicySource
        let usedCachedPolicy: Bool
        let relayURLs: [String]
        /// Start of the current run of consecutive policy refresh failures,
        /// mirrored from the service diagnostics so an unreachable-by-outage
        /// host is visible in `iroh_diag` (cmux#10873).
        let refreshFailingSince: Date?
        let consecutiveRefreshFailures: Int

        init(
            source: CmxIrohRelayPolicySource,
            usedCachedPolicy: Bool,
            relayURLs: [String],
            refreshFailingSince: Date? = nil,
            consecutiveRefreshFailures: Int = 0
        ) {
            self.source = source
            self.usedCachedPolicy = usedCachedPolicy
            self.relayURLs = relayURLs
            self.refreshFailingSince = refreshFailingSince
            self.consecutiveRefreshFailures = consecutiveRefreshFailures
        }
    }

    /// The refresh failure streak alone, for the launches where no relay
    /// policy was ever installed but the refresh loop is failing: the diag
    /// must say why relays are absent instead of only "none installed".
    struct RelayDiagRefreshFailure: Equatable, Sendable {
        let since: Date
        let consecutiveFailures: Int
    }

    /// Mirror of the relay policy most recently installed by the account
    /// pipeline. A lock rather than an actor, deliberately (matching the
    /// `AgentChatThemeSync` precedent and the `hostDiagnosticLog` design):
    /// the write must be visible synchronously when the
    /// `relayPolicyEffective` didSet returns (an actor write would be a
    /// detached hop, letting a concurrent `iroh_diag` read report the
    /// previous policy after installation), and the read must stay off the
    /// main actor so the verb keeps working when the main thread is wedged.
    /// Both critical sections are tiny value copies with no reentrancy.
    private nonisolated static let relayDiagMirror = OSAllocatedUnfairLock<RelayDiagMirror>(
        initialState: RelayDiagMirror(policy: nil, refreshFailure: nil)
    )

    struct RelayDiagMirror: Equatable, Sendable {
        var policy: RelayDiagState?
        var refreshFailure: RelayDiagRefreshFailure?
    }

    /// The single write funnel, called from the `relayPolicyEffective` and
    /// `relayPolicyDiagnostics` `didSet`s so every installation, clearing,
    /// and refresh-outcome site is mirrored before the property write
    /// returns.
    static func publishRelayDiagMirror(
        from policy: CmxIrohEffectiveRelayPolicy?,
        diagnostics: CmxIrohRelayDiagnosticsSnapshot?
    ) {
        let refreshFailure = diagnostics?.refreshFailingSince.map {
            RelayDiagRefreshFailure(
                since: $0,
                consecutiveFailures: diagnostics?.consecutiveRefreshFailures ?? 0
            )
        }
        let state = policy.map {
            RelayDiagState(
                source: $0.source,
                usedCachedPolicy: $0.usedCachedPolicy,
                relayURLs: $0.endpointRelayProfile.allowedRelayURLs.sorted(),
                refreshFailingSince: refreshFailure?.since,
                consecutiveRefreshFailures: refreshFailure?.consecutiveFailures ?? 0
            )
        }
        relayDiagMirror.withLock {
            $0 = RelayDiagMirror(policy: state, refreshFailure: refreshFailure)
        }
    }

    nonisolated static func currentRelayDiagState() -> RelayDiagState? {
        relayDiagMirror.withLock { $0.policy }
    }

    /// The relay section appended to `iroh_diag` output: the profile the
    /// endpoint is actually using, and whether it came from the managed
    /// catalog, a custom profile, or the debug override. The override is
    /// consulted first because every profile installation funnel replaces
    /// the installed profile with it while it is active.
    nonisolated static func relayDiagReportText() -> String {
        let mirror = relayDiagMirror.withLock { $0 }
        return relayDiagReport(
            policy: mirror.policy,
            refreshFailure: mirror.refreshFailure,
            debugOverrideRelayURL: CmxIrohDebugRelayOverrideDiagnostics().activeRelayURL
        )
    }

    nonisolated static func relayDiagReport(
        policy: RelayDiagState?,
        refreshFailure: RelayDiagRefreshFailure? = nil,
        debugOverrideRelayURL: String?
    ) -> String {
        var lines = ["Active relay profile"]
        if let debugOverrideRelayURL {
            let key = CmxIrohDebugRelayOverrideDiagnostics().overrideKey
            lines.append("Source: debug override (\(key))")
            lines.append("Relays: \(debugOverrideRelayURL)")
            return lines.joined(separator: "\n")
        }
        guard let policy else {
            if let refreshFailure {
                lines.append(
                    "Source: none — policy refresh failing since "
                        + iso8601(refreshFailure.since)
                        + " (\(refreshFailure.consecutiveFailures) consecutive failures)"
                )
            } else {
                lines.append("Source: none installed (no relay policy this launch)")
            }
            return lines.joined(separator: "\n")
        }
        let source = switch policy.source {
        case .inactive:
            "inactive (no account policy restored)"
        case .managed:
            policy.usedCachedPolicy ? "managed catalog (cached)" : "managed catalog"
        case .custom:
            "custom"
        case .managedUnavailable:
            "managed selection unavailable (relays disabled)"
        case .customUnavailable:
            "custom selection unavailable (relays disabled)"
        }
        lines.append("Source: \(source)")
        if policy.relayURLs.isEmpty {
            lines.append("Relays: (none)")
        } else {
            lines.append("Relays: \(policy.relayURLs.joined(separator: ", "))")
        }
        if let since = policy.refreshFailingSince {
            lines.append(
                "Policy refresh: failing since " + iso8601(since)
                    + " (\(policy.consecutiveRefreshFailures) consecutive failures)"
            )
        }
        return lines.joined(separator: "\n")
    }

    private nonisolated static func iso8601(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}
