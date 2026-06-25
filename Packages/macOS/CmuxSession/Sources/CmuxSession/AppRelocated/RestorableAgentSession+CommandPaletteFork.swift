import Foundation
import CmuxCommandPalette

// MARK: - Command-palette fork availability / fingerprint

/// Pure fork-availability and fork-fingerprint computations over a
/// ``SessionRestorableAgentSnapshot``.
///
/// These were lifted off the `ContentView` god view: every method computes
/// purely over the snapshot's value fields (`kind`/`forkCommand`/`launchCommand`/
/// `sessionId`/`workingDirectory`) and returns either a pure `String` fingerprint
/// or the package value ``CmuxCommandPalette/CommandPaletteForkSnapshotAvailability``.
/// They live on the snapshot value type (their natural receiver) rather than on
/// the view that happened to host the command palette.
extension SessionRestorableAgentSnapshot {
    /// Classifies whether this snapshot can seed a fork command and whether
    /// confirming that needs an asynchronous capability probe.
    ///
    /// `.unsupported` when there is no `forkCommand`, or when a remote terminal
    /// cannot produce inline fork startup input. Claude/Codex are always
    /// fork-able without a probe; opencode needs a version probe unless launched
    /// via `omo` or running remotely; custom agents trust their registration's
    /// `forkCommand` template.
    func commandPaletteForkAvailability(
        isRemoteTerminal: Bool = false
    ) -> CommandPaletteForkSnapshotAvailability {
        guard forkCommand != nil else { return .unsupported }
        if isRemoteTerminal,
           forkStartupInput(allowLauncherScript: false) == nil {
            return .unsupported
        }
        switch kind {
        case .claude, .codex:
            return .supportedWithoutProbe
        case .opencode:
            return launchCommand?.launcher == "omo" || isRemoteTerminal ? .supportedWithoutProbe : .requiresProbe
        case .custom:
            // Reaching here means `forkCommand != nil` (top guard), i.e. the
            // agent's registration declares a `forkCommand` template, so it is
            // fork-able. There is no per-agent fork-capability probe for custom
            // agents (unlike opencode's version probe), so trust the template.
            return .supportedWithoutProbe
        default:
            return .unsupported
        }
    }

    /// Stable fingerprint of this snapshot, used to detect when a panel's
    /// fallback snapshot changed and a cached fork-probe result must be
    /// invalidated. Joins the identity + launch-command fields with the unit/
    /// record separator control characters so no field value can collide across
    /// the join.
    var commandPaletteForkFingerprint: String {
        let launchCommand = launchCommand
        let launchArguments = launchCommand?.arguments.joined(separator: "\u{1f}") ?? ""
        let parts: [String] = [
            kind.rawValue,
            sessionId,
            workingDirectory ?? "",
            launchCommand?.launcher ?? "",
            launchCommand?.executablePath ?? "",
            launchArguments,
            launchCommand?.workingDirectory ?? "",
            launchCommand?.source ?? "",
            forkCommand ?? ""
        ]
        return parts.joined(separator: "\u{1e}")
    }

    /// The fingerprint to cache for a fork-probe result: the explicit
    /// `fallbackFingerprint` when present, otherwise the snapshot's own
    /// fingerprint.
    static func commandPaletteForkCacheFingerprint(
        snapshot: SessionRestorableAgentSnapshot,
        fallbackFingerprint: String?
    ) -> String {
        fallbackFingerprint ?? snapshot.commandPaletteForkFingerprint
    }

    /// Whether the panel at `(workspaceId, panelId)` currently has a fork-able
    /// agent, given the probe coordinator's supported-panel state and the panel's
    /// fallback snapshot.
    ///
    /// The panel must be in `supportedPanelKeys`, its remote context (if known)
    /// must match `isRemoteTerminal`, and when a `fallbackSnapshot` is present it
    /// must itself be fork-available. The panel-key derivation stays on
    /// ``ContentView`` because it is owned by the command-palette probe
    /// coordinator.
    static func commandPalettePanelHasForkableAgent(
        workspaceId: UUID,
        panelId: UUID,
        supportedPanelKeys: Set<String>,
        supportedRemoteContextsByPanelKey: [String: Bool] = [:],
        fallbackSnapshot: SessionRestorableAgentSnapshot?,
        isRemoteTerminal: Bool = false
    ) -> Bool {
        let panelKey = ContentView.commandPaletteForkableAgentPanelKey(
            workspaceId: workspaceId,
            panelId: panelId
        )
        if supportedPanelKeys.contains(panelKey) {
            if let supportedRemoteContext = supportedRemoteContextsByPanelKey[panelKey],
               supportedRemoteContext != isRemoteTerminal {
                return false
            }
            if let fallbackSnapshot {
                return fallbackSnapshot.commandPaletteForkAvailability(
                    isRemoteTerminal: isRemoteTerminal
                ) != .unsupported
            }
            return true
        }
        return false
    }
}
