public import Combine
public import Foundation
public import Observation

/// The per-workspace surface-directory sub-model: owns the directory-report
/// and listening-port-fusion logic the legacy `Workspace` god object kept
/// inline (`updatePanelDirectory`, `configTrackingDirectory`,
/// `shouldIgnoreRestoredGuardedDirectoryReport`, `unmountedVolumeRoot`,
/// `resolvedWorkingDirectory`, `recomputeListeningPorts`), plus the
/// conversation/submitted-message previews and the fused listening-port
/// projection the legacy god object kept as loose `@Published` stored
/// properties (`latestConversationMessage`, `latestSubmittedMessage`,
/// `latestSubmittedAt`, `listeningPorts`).
///
/// The per-surface directory map (`panelDirectories`) and per-surface
/// listening-port map (`surfaceListeningPorts`) live in the shared
/// ``SurfaceRegistryModel`` this model is constructed with, so the model reads
/// and writes them directly. Everything else the bodies touched (the focused
/// panel, the `@Published` `currentDirectory` / `surfaceTabBarDirectory`, the
/// remote-tmux-mirror flag, a terminal panel's requested working directory,
/// the restored-guarded-directory guard map, and the agent/remote port sets)
/// is reached through ``SurfaceMetadataHosting``, conformed by `Workspace` and
/// injected via ``attach(host:)``.
///
/// `Workspace` owns one instance and forwards each former method and stored
/// property through a one-line call/computed pair, so every call site stays
/// byte-identical.
///
/// Byte-identical observer parity: `latestConversationMessage`,
/// `latestSubmittedMessage`, `latestSubmittedAt`, and `listeningPorts` were
/// `@Published` on the legacy `ObservableObject` `Workspace` and their
/// `$projection`s fed `WorkspaceSidebarObservation`'s fused `CombineLatest` +
/// `removeDuplicates()` sidebar publishers. To preserve that exactly, each
/// mirrors its value into a `CurrentValueSubject` in `didSet` and exposes a
/// matching `…Publisher` accessor replacing the former `$property`:
/// replay-on-subscribe + send-on-every-assignment reproduces the `@Published`
/// contract those `.map { _ in () }` subscribers relied on, so the debounced
/// sidebar refresh fires at the same moments. This matches the convention the
/// sibling ``SurfaceRegistryModel`` uses for `panelDirectories` / `panelTitles`
/// / `panelCustomTitles`. `panelDirectories` already mirrors its own Combine
/// subject inside ``SurfaceRegistryModel``, and the `currentDirectory` /
/// `surfaceTabBarDirectory` writes go through the host's own `@Published`
/// properties, preserving their emission moments.
@MainActor
@Observable
public final class WorkspaceSurfaceMetadataModel<TabSelectionRequest> {
    @ObservationIgnored
    private let registry: SurfaceRegistryModel<TabSelectionRequest>

    @ObservationIgnored
    private weak var host: (any SurfaceMetadataHosting)?

    /// The latest assistant/conversation message preview (legacy
    /// `Workspace.latestConversationMessage`, a `@Published private(set)`).
    public var latestConversationMessage: String? {
        didSet { latestConversationMessageSubject.send(latestConversationMessage) }
    }

    /// The latest submitted-prompt preview (legacy
    /// `Workspace.latestSubmittedMessage`, a `@Published private(set)`).
    public var latestSubmittedMessage: String? {
        didSet { latestSubmittedMessageSubject.send(latestSubmittedMessage) }
    }

    /// The timestamp of the latest submitted prompt (legacy
    /// `Workspace.latestSubmittedAt`, a `@Published private(set)`).
    public var latestSubmittedAt: Date? {
        didSet { latestSubmittedAtSubject.send(latestSubmittedAt) }
    }

    /// The fused, sorted, deduplicated workspace listening-port projection
    /// (legacy `Workspace.listeningPorts`, a `@Published var`).
    public var listeningPorts: [Int] = [] {
        didSet { listeningPortsSubject.send(listeningPorts) }
    }

    @ObservationIgnored
    private lazy var latestConversationMessageSubject = CurrentValueSubject<String?, Never>(latestConversationMessage)
    @ObservationIgnored
    private lazy var latestSubmittedMessageSubject = CurrentValueSubject<String?, Never>(latestSubmittedMessage)
    @ObservationIgnored
    private lazy var latestSubmittedAtSubject = CurrentValueSubject<Date?, Never>(latestSubmittedAt)
    @ObservationIgnored
    private lazy var listeningPortsSubject = CurrentValueSubject<[Int], Never>(listeningPorts)

    /// Emits the current conversation-message preview on subscription, then on
    /// every change (replaces the legacy `Workspace.$latestConversationMessage`).
    public var latestConversationMessagePublisher: AnyPublisher<String?, Never> {
        latestConversationMessageSubject.eraseToAnyPublisher()
    }

    /// Emits the current submitted-message preview on subscription, then on
    /// every change (replaces the legacy `Workspace.$latestSubmittedMessage`).
    public var latestSubmittedMessagePublisher: AnyPublisher<String?, Never> {
        latestSubmittedMessageSubject.eraseToAnyPublisher()
    }

    /// Emits the current submitted-at timestamp on subscription, then on every
    /// change (replaces the legacy `Workspace.$latestSubmittedAt`).
    public var latestSubmittedAtPublisher: AnyPublisher<Date?, Never> {
        latestSubmittedAtSubject.eraseToAnyPublisher()
    }

    /// Emits the current fused listening ports on subscription, then on every
    /// change (replaces the legacy `Workspace.$listeningPorts`).
    public var listeningPortsPublisher: AnyPublisher<[Int], Never> {
        listeningPortsSubject.eraseToAnyPublisher()
    }

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
        // A remote workspace's directories are paths on the REMOTE host.
        // Feeding one into local cmux.json tracking makes CmuxConfigStore walk
        // the ancestor chain with FileManager.fileExists on the main thread,
        // and stat'ing e.g. /home/… locally blocks on the autofs automounter
        // for hundreds of ms (measured via sample during tab-reveal stalls).
        // No local per-directory config can apply to a remote path — track none.
        if host?.surfaceMetadataUsesRemoteDirectoryProvenance == true { return nil }
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
        if source.isLiveReport,
           shouldIgnoreRestoredGuardedDirectoryReport(panelId: panelId, reportedDirectory: trimmed) {
            return false
        }
        if registry.panelDirectories[panelId] != trimmed {
            registry.panelDirectories[panelId] = trimmed
        }
        // Update current directory if this is the focused panel
        if panelId == host?.surfaceMetadataFocusedPanelId {
            let nextSurfaceTabBarDirectory = configTrackingDirectory(for: panelId)
            if host?.surfaceMetadataSurfaceTabBarDirectory != nextSurfaceTabBarDirectory {
                host?.surfaceMetadataSurfaceTabBarDirectory = nextSurfaceTabBarDirectory
            }
            if host?.surfaceMetadataAllowsLocalDirectoryFallback(panelId: panelId) == true,
               host?.surfaceMetadataCurrentDirectory != trimmed {
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

        if let missingVolumeRoot = Self.unmountedVolumeRoot(for: restoredDirectory) {
            host?.surfaceMetadataLogIgnoredRestoredCwdReport(
                panelId: panelId,
                missingVolumeRoot: missingVolumeRoot,
                savedDirectory: restoredDirectory,
                reportedDirectory: reportedDirectory
            )
            return true
        }

        host?.surfaceMetadataClearRestoredGuardedWorkingDirectory(panelId: panelId)
        var restoredDirectoryIsDirectory = ObjCBool(false)
        let restoredDirectoryStillExists = FileManager.default.fileExists(
            atPath: restoredDirectory,
            isDirectory: &restoredDirectoryIsDirectory
        ) && restoredDirectoryIsDirectory.boolValue
        if !restoredDirectoryStillExists {
            host?.surfaceMetadataClearRestoredResumeSessionWorkingDirectory(panelId: panelId)
        }
        host?.surfaceMetadataLogRestoredCwdDecision(
            panelId: panelId,
            event: restoredDirectoryStillExists ? "ignoredOnce" : "accepted",
            savedDirectory: restoredDirectory,
            reportedDirectory: reportedDirectory
        )
        return restoredDirectoryStillExists
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

    /// Records the latest assistant/conversation `message` preview, returning
    /// `true` exactly when a new, non-empty preview was stored.
    ///
    /// Owns the legacy `Workspace.recordConversationMessage(_:)` decision: derive
    /// the preview, ignore a `nil`/whitespace-only message, ignore an unchanged
    /// preview, then write ``latestConversationMessage``. The storage now lives
    /// on this model (its ``latestConversationMessagePublisher`` feeds the
    /// sidebar observation publisher in place of the former
    /// `$latestConversationMessage`), so the conditional write is byte-identical
    /// to the legacy guard.
    @discardableResult
    public func recordConversationMessage(_ message: String?) -> Bool {
        guard let preview = Self.conversationMessagePreview(from: message) else { return false }
        guard latestConversationMessage != preview else { return false }
        latestConversationMessage = preview
        return true
    }

    /// Records a submitted-prompt `message`: stores its preview as both the
    /// latest conversation message and the latest submitted message, and stamps
    /// ``latestSubmittedAt`` with the current time. Returns `true` when a
    /// non-empty preview was recorded. Faithful lift of
    /// `Workspace.recordSubmittedMessage(_:)`; the storage now lives on this
    /// model so the writes and their emission moments are byte-identical.
    @discardableResult
    public func recordSubmittedMessage(_ message: String?) -> Bool {
        guard let preview = Self.conversationMessagePreview(from: message) else { return false }
        _ = recordConversationMessage(preview)
        latestSubmittedMessage = preview
        latestSubmittedAt = Date()
        return true
    }

    /// Recomputes the fused, sorted, deduplicated workspace listening-port
    /// projection from the per-surface registry ports plus the agent and remote
    /// port sets, writing ``listeningPorts`` only when it changes. Faithful lift
    /// of `Workspace.recomputeListeningPorts()`.
    public func recomputeListeningPorts() {
        guard let host else { return }
        let unique = Set(registry.surfaceListeningPorts.values.flatMap { $0 })
            .union(host.surfaceMetadataAgentListeningPorts)
            .union(host.surfaceMetadataRemoteDetectedPorts)
            .union(host.surfaceMetadataRemoteForwardedPorts)
        let next = unique.sorted()
        if listeningPorts != next {
            listeningPorts = next
        }
    }
}
