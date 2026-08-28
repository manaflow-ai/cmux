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
    private nonisolated static let relayDiagMirror = OSAllocatedUnfairLock<RelayDiagState?>(
        initialState: nil
    )

    /// The single write funnel, called from `relayPolicyEffective`'s
    /// `didSet` so every installation and clearing site is mirrored before
    /// the property write returns.
    static func publishRelayDiagMirror(from policy: CmxIrohEffectiveRelayPolicy?) {
        let state = policy.map {
            RelayDiagState(
                source: $0.source,
                usedCachedPolicy: $0.usedCachedPolicy,
                relayURLs: $0.endpointRelayProfile.allowedRelayURLs.sorted()
            )
        }
        relayDiagMirror.withLock { $0 = state }
    }

    nonisolated static func currentRelayDiagState() -> RelayDiagState? {
        relayDiagMirror.withLock { $0 }
    }

    /// The relay section appended to `iroh_diag` output: the profile the
    /// endpoint is actually using, and whether it came from the managed
    /// catalog, a custom profile, or the debug override. The override is
    /// consulted first because every profile installation funnel replaces
    /// the installed profile with it while it is active.
    nonisolated static func relayDiagReportText() -> String {
        relayDiagReport(
            policy: currentRelayDiagState(),
            debugOverrideRelayURL: CmxIrohDebugRelayOverrideDiagnostics().activeRelayURL
        )
    }

    nonisolated static func relayDiagReport(
        policy: RelayDiagState?,
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
            lines.append("Source: none installed (no relay policy this launch)")
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
        return lines.joined(separator: "\n")
    }
}
