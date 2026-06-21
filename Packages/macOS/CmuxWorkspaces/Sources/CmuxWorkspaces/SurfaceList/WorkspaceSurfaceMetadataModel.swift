public import Foundation

/// The per-workspace surface-directory sub-model: owns the directory-report
/// and listening-port-fusion logic the legacy `Workspace` god object kept
/// inline (`updatePanelDirectory`, `configTrackingDirectory`,
/// `shouldIgnoreRestoredGuardedDirectoryReport`, `unmountedVolumeRoot`,
/// `resolvedWorkingDirectory`, `recomputeListeningPorts`).
///
/// The per-surface directory map (`panelDirectories`) and per-surface
/// listening-port map (`surfaceListeningPorts`) live in the shared
/// ``SurfaceRegistryModel`` this model is constructed with, so the model reads
/// and writes them directly. Everything else the bodies touched (the focused
/// panel, the `@Published` `currentDirectory` / `surfaceTabBarDirectory`, the
/// remote-tmux-mirror flag, a terminal panel's requested working directory,
/// the restored-guarded-directory guard map, the agent/remote port sets, and
/// the fused `listeningPorts` projection) is reached through
/// ``SurfaceMetadataHosting``, conformed by `Workspace` and injected via
/// ``attach(host:)``.
///
/// `Workspace` owns one instance and forwards each former method through a
/// one-line call, so every call site stays byte-identical. There is no
/// observer-parity bridge here: `panelDirectories` already mirrors its own
/// Combine subject inside ``SurfaceRegistryModel``, and the `@Published`
/// `currentDirectory` / `surfaceTabBarDirectory` / `listeningPorts` writes go
/// through the host's own properties, preserving their emission moments.
@MainActor
public final class WorkspaceSurfaceMetadataModel<TabSelectionRequest> {
    private let registry: SurfaceRegistryModel<TabSelectionRequest>

    private weak var host: (any SurfaceMetadataHosting)?

    /// Creates the model over the workspace's shared surface registry. Call
    /// ``attach(host:)`` at the composition point before any directory report
    /// is applied.
    public init(registry: SurfaceRegistryModel<TabSelectionRequest>) {
        self.registry = registry
    }

    /// Injects the live-workspace seam. Set before the model applies a
    /// directory report so the focused-directory propagation and port fusion
    /// reach the workspace.
    public func attach(host: any SurfaceMetadataHosting) {
        self.host = host
    }

    /// The `/Volumes/<name>` root that `workingDirectory` lives under when that
    /// volume is not currently mounted, or `nil` when the path is not under an
    /// unmounted volume. Faithful lift of `Workspace.unmountedVolumeRoot(for:)`.
    public static func unmountedVolumeRoot(
        for workingDirectory: String,
        fileManager: FileManager = .default
    ) -> String? {
        let trimmed = workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let components = URL(fileURLWithPath: trimmed, isDirectory: true)
            .standardizedFileURL
            .pathComponents
        guard components.count >= 3,
              components[0] == "/",
              components[1] == "Volumes",
              !components[2].isEmpty else {
            return nil
        }

        let volumeRoot = "/Volumes/\(components[2])"
        return fileManager.fileExists(atPath: volumeRoot) ? nil : volumeRoot
    }

    /// The working directory app-level actions (diff viewer, configured commands)
    /// should target for this workspace: the focused panel's tracked directory, then
    /// its terminal's requested directory, then the workspace's current directory.
    /// Returns `nil` when none is known so callers can apply their own fallback.
    ///
    /// This is the focused-panel case of ``configTrackingDirectory(for:)`` (the same
    /// three-tier order); the tiers are spelled out here so the public entry point is
    /// self-contained. Faithful lift of `Workspace.resolvedWorkingDirectory()`.
    public func resolvedWorkingDirectory() -> String? {
        let focusedPanelId = host?.surfaceMetadataFocusedPanelId
        let candidates = [
            focusedPanelId.flatMap { registry.panelDirectories[$0] },
            focusedPanelId.flatMap { host?.surfaceMetadataRequestedWorkingDirectory(panelId: $0) },
            host?.surfaceMetadataCurrentDirectory,
        ]
        for candidate in candidates {
            let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }

    /// The directory cmux.json per-directory config tracking should follow for
    /// `panelId` (focused-panel directory, then terminal requested directory,
    /// then workspace current directory), or `nil` for a remote tmux mirror or
    /// when nothing is known. Faithful lift of
    /// `Workspace.configTrackingDirectory(for:)`.
    public func configTrackingDirectory(for panelId: UUID?) -> String? {
        // A remote tmux mirror's directories are paths on the REMOTE host.
        // Feeding one into local cmux.json tracking makes CmuxConfigStore walk
        // the ancestor chain with FileManager.fileExists on the main thread,
        // and stat'ing e.g. /home/… locally blocks on the autofs automounter
        // for hundreds of ms (measured via sample during tab-reveal stalls).
        // No local per-directory config can apply to a remote path — track none.
        if host?.surfaceMetadataIsRemoteTmuxMirror == true { return nil }
        if let panelId {
            for candidate in [
                registry.panelDirectories[panelId],
                host?.surfaceMetadataRequestedWorkingDirectory(panelId: panelId)
            ] {
                let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }

        let trimmedCurrentDirectory = (host?.surfaceMetadataCurrentDirectory ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedCurrentDirectory.isEmpty ? nil : trimmedCurrentDirectory
    }

    /// Records a live `directory` report for `panelId` (legacy
    /// `Workspace.updatePanelDirectory(panelId:directory:)`, the public
    /// `.liveReport` entry point).
    @discardableResult
    public func updatePanelDirectory(panelId: UUID, directory: String) -> Bool {
        updatePanelDirectory(panelId: panelId, directory: directory, source: .liveReport)
    }

    /// Records a `directory` report for `panelId` from `source`. Faithful lift
    /// of the private `Workspace.updatePanelDirectory(panelId:directory:source:)`.
    @discardableResult
    public func updatePanelDirectory(
        panelId: UUID,
        directory: String,
        source: PanelDirectoryUpdateSource
    ) -> Bool {
        let trimmed = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if source == .liveReport,
           shouldIgnoreRestoredGuardedDirectoryReport(panelId: panelId, reportedDirectory: trimmed) {
            return false
        }
        if registry.panelDirectories[panelId] != trimmed {
            registry.panelDirectories[panelId] = trimmed
        }
        // Update current directory if this is the focused panel
        if panelId == host?.surfaceMetadataFocusedPanelId {
            if host?.surfaceMetadataSurfaceTabBarDirectory != trimmed {
                host?.surfaceMetadataSurfaceTabBarDirectory = trimmed
            }
            if host?.surfaceMetadataCurrentDirectory != trimmed {
                host?.surfaceMetadataCurrentDirectory = trimmed
            }
        }
        return true
    }

    /// Whether a live cwd report for a restored guarded surface should be
    /// ignored because the surface's saved volume is still unmounted. Faithful
    /// lift of `Workspace.shouldIgnoreRestoredGuardedDirectoryReport(panelId:reportedDirectory:)`.
    private func shouldIgnoreRestoredGuardedDirectoryReport(
        panelId: UUID,
        reportedDirectory: String
    ) -> Bool {
        guard let restoredDirectory = host?.surfaceMetadataRestoredGuardedWorkingDirectory(panelId: panelId) else {
            return false
        }

        if reportedDirectory == restoredDirectory {
            host?.surfaceMetadataClearRestoredGuardedWorkingDirectory(panelId: panelId)
            return false
        }

        let missingVolumeRoot = Self.unmountedVolumeRoot(for: restoredDirectory)
        guard missingVolumeRoot != nil else {
            host?.surfaceMetadataClearRestoredGuardedWorkingDirectory(panelId: panelId)
            return false
        }

        host?.surfaceMetadataLogIgnoredRestoredCwdReport(
            panelId: panelId,
            missingVolumeRoot: missingVolumeRoot ?? "",
            savedDirectory: restoredDirectory,
            reportedDirectory: reportedDirectory
        )
        return true
    }

    /// Records `state` as the shell-activity classification for `panelId`,
    /// returning the panel's previous state exactly when the report represents a
    /// real transition the caller must act on, and `nil` otherwise.
    ///
    /// This owns the registry half of the legacy
    /// `Workspace.updatePanelShellActivityState(panelId:state:)`: the
    /// absent-panel guard (through ``SurfaceMetadataHosting/surfaceMetadataPanelExists(panelId:)``),
    /// the unchanged-state guard, and the `panelShellActivityStates` write. Both
    /// guards return `nil` so the caller skips the tail; only a landed write
    /// returns the previous state.
    ///
    /// The tail the legacy body ran after the write, the restored-agent
    /// resume-state update (it reaches `restoredAgentSnapshotsByPanelId` and the
    /// agent-hibernation coordinator) and the DEBUG `surface.shellState` log
    /// (it needs the workspace-id prefix and the `cmuxDebugLog` sink), is
    /// irreducibly app-coupled, so the `Workspace` shim performs it with the
    /// returned previous state. `panelShellActivityStates` carries no Combine
    /// subscriber, so the direct registry write needs no observer-parity bridge.
    @discardableResult
    public func applyPanelShellActivityState(
        panelId: UUID,
        state: PanelShellActivityState
    ) -> PanelShellActivityState? {
        guard host?.surfaceMetadataPanelExists(panelId: panelId) == true else { return nil }
        let previousState = registry.panelShellActivityStates[panelId] ?? .unknown
        guard previousState != state else { return nil }
        registry.panelShellActivityStates[panelId] = state
        return previousState
    }

    /// The single-line preview cmux derives from a conversation or submitted
    /// message before recording it: whitespace-collapsed, trimmed, and truncated
    /// to `maxLength` with a trailing ellipsis. Returns `nil` for a `nil` or
    /// whitespace-only message. Faithful lift of the pure
    /// `Workspace.conversationMessagePreview(from:maxLength:)`.
    public static func conversationMessagePreview(
        from message: String?,
        maxLength: Int = 240
    ) -> String? {
        guard let message else { return nil }
        let collapsed = message
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return nil }
        guard collapsed.count > maxLength else { return collapsed }
        return "\(collapsed.prefix(maxLength))..."
    }

    /// Records the latest assistant/conversation `message` preview on the host,
    /// returning `true` exactly when a new, non-empty preview was stored.
    ///
    /// Owns the legacy `Workspace.recordConversationMessage(_:)` decision: derive
    /// the preview, ignore a `nil`/whitespace-only message, ignore an unchanged
    /// preview, then write `latestConversationMessage` through the host seam. The
    /// `@Published` storage stays on `Workspace` (its `$latestConversationMessage`
    /// projection feeds the sidebar observation publisher), so the write goes
    /// through ``SurfaceMetadataHosting/surfaceMetadataLatestConversationMessage``;
    /// its emission moment is the host property's, preserving observer parity.
    @discardableResult
    public func recordConversationMessage(_ message: String?) -> Bool {
        guard let preview = Self.conversationMessagePreview(from: message) else { return false }
        guard host?.surfaceMetadataLatestConversationMessage != preview else { return false }
        host?.surfaceMetadataLatestConversationMessage = preview
        return true
    }

    /// Records a submitted-prompt `message`: stores its preview as both the
    /// latest conversation message and the latest submitted message, and stamps
    /// `latestSubmittedAt` with the current time. Returns `true` when a non-empty
    /// preview was recorded. Faithful lift of
    /// `Workspace.recordSubmittedMessage(_:)`; the submitted writes go through the
    /// host seam so the `@Published` storage and its emission moments stay on
    /// `Workspace`.
    @discardableResult
    public func recordSubmittedMessage(_ message: String?) -> Bool {
        guard let preview = Self.conversationMessagePreview(from: message) else { return false }
        _ = recordConversationMessage(preview)
        host?.surfaceMetadataLatestSubmittedMessage = preview
        host?.surfaceMetadataLatestSubmittedAt = Date()
        return true
    }

    /// Recomputes the fused, sorted, deduplicated workspace listening-port
    /// projection from the per-surface registry ports plus the agent and remote
    /// port sets, writing the host's `listeningPorts` only when it changes.
    /// Faithful lift of `Workspace.recomputeListeningPorts()`.
    public func recomputeListeningPorts() {
        guard let host else { return }
        let unique = Set(registry.surfaceListeningPorts.values.flatMap { $0 })
            .union(host.surfaceMetadataAgentListeningPorts)
            .union(host.surfaceMetadataRemoteDetectedPorts)
            .union(host.surfaceMetadataRemoteForwardedPorts)
        let next = unique.sorted()
        if host.surfaceMetadataListeningPorts != next {
            host.surfaceMetadataListeningPorts = next
        }
    }
}
