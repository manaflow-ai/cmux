import CmuxIrohTransport
import Foundation

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

    nonisolated static let relayDiagMirror = MobileHostRelayDiagMirror()

    /// Monotonic write order for ``relayDiagMirror``, owned by the main
    /// actor because every ``relayPolicyEffective`` write happens there.
    private static var relayDiagRevision: UInt64 = 0

    /// The single write funnel, called from `relayPolicyEffective`'s
    /// `didSet` so every installation and clearing site is mirrored.
    static func publishRelayDiagMirror(from policy: CmxIrohEffectiveRelayPolicy?) {
        relayDiagRevision &+= 1
        let revision = relayDiagRevision
        let state = policy.map {
            RelayDiagState(
                source: $0.source,
                usedCachedPolicy: $0.usedCachedPolicy,
                relayURLs: $0.endpointRelayProfile.allowedRelayURLs.sorted()
            )
        }
        Task {
            await relayDiagMirror.apply(revision: revision, state: state)
        }
    }

    /// The relay section appended to `iroh_diag` output: the profile the
    /// endpoint is actually using, and whether it came from the managed
    /// catalog, a custom profile, or the debug override. The override is
    /// consulted first because every profile installation funnel replaces
    /// the installed profile with it while it is active.
    nonisolated static func relayDiagReportText() async -> String {
        relayDiagReport(
            policy: await relayDiagMirror.current(),
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
