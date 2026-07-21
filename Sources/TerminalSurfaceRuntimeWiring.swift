import AppKit
import Foundation
import CmuxTerminal
import CmuxTerminalCore
import GhosttyKit
import CmuxSettings
import CmuxGhosttyRenderClient
import CmuxTerminalRenderTransport
import struct CmuxSettings.AgentIntegrationSettingsStore

// The app-side conformances and bridges injected into the CmuxTerminal
// package through `GhosttyApp.terminalSurfaceRuntimeDependencies`. Each type
// here carries behavior verbatim from the legacy god-file reach-up it
// replaces; this file is intended composition-root residue.

// MARK: Engine

extension GhosttyApp: TerminalEngineHosting {
    var runtimeApp: ghostty_app_t? { app }
    var runtimeConfig: ghostty_config_t? { config }
    // `userGhosttyShellIntegrationMode` already matches the seam requirement.
}

// MARK: Views

/// Creates the concrete `GhosttyNSView` + `GhosttySurfaceScrollView` pair the
/// surface model historically constructed in its initializer.
struct TerminalSurfaceViewFactory: TerminalSurfaceViewProviding {
    @MainActor
    func makeSurfaceViews(
        initialFrame: NSRect
    ) -> (surfaceView: any TerminalSurfaceNativeViewing, paneHost: any TerminalSurfacePaneHosting) {
        let view = GhosttyNSView(frame: initialFrame)
        return (view, GhosttySurfaceScrollView(surfaceView: view))
    }
}

// MARK: Spawn policy

/// Live settings/control-plane reads for spawn assembly (the legacy inline
/// reads of the integration-settings enums, `sidebarShellIntegration`,
/// `SidebarWorkspaceDetailDefaults`, and `TerminalController`'s socket path).
@MainActor
final class TerminalSurfaceSpawnPolicyBridge: TerminalSurfaceSpawnPolicyProviding {
    func currentSpawnPolicy() -> TerminalSurfaceSpawnPolicy {
        let integrations = AgentIntegrationSettingsStore(defaults: .standard)
        return TerminalSurfaceSpawnPolicy(
            socketAuthenticationEnvironment: TerminalController.shared.socketClientCapabilityEnvironment(),
            claudeHooksEnabled: integrations.claudeCodeHooksEnabled,
            codexHooksEnabled: integrations.codexHooksEnabled,
            customClaudePath: integrations.customClaudePath,
            subagentNotificationEnvironmentKey: AgentIntegrationSettingsStore.subagentSuppressionEnvironmentKey,
            suppressSubagentNotifications: integrations.suppressesSubagentNotifications,
            cursorHooksEnabled: integrations.cursorHooksEnabled,
            geminiHooksEnabled: integrations.geminiHooksEnabled,
            kiroHooksEnabled: integrations.kiroHooksEnabled,
            kiroNotificationLevel: integrations.kiroNotificationLevel.rawValue,
            ampHooksEnabled: integrations.ampHooksEnabled,
            shellIntegrationEnabled: UserDefaults.standard.object(forKey: "sidebarShellIntegration") as? Bool ?? true,
            watchGitStatusEnabled: SidebarWorkspaceDetailDefaults.watchGitStatusValue(defaults: .standard),
            showPullRequestsEnabled: SidebarWorkspaceDetailDefaults.showPullRequestsValue(defaults: .standard)
        )
    }

    func controlSocketPath() -> String {
        TerminalController.shared.activeSocketPath(
            preferredPath: SocketControlSettings.socketPath()
        )
    }
}

// MARK: Terminal output tee

/// Installs the libghostty PTY tee for `MobileTerminalByteTee` and keys
/// drop/replay state by surface id (the legacy inline
/// `ghostty_surface_set_pty_tee_cb` + `MobileTerminalByteTee.shared` calls).
final class TerminalOutputByteTeeBridge: TerminalByteTeeBinding {
    private let renderWorker: any TerminalRenderWorkerRouting

    init(renderWorker: any TerminalRenderWorkerRouting) {
        self.renderWorker = renderWorker
    }
    /// Wraps the retained tee userdata; `release()` runs exactly where the
    /// surface released the legacy `Unmanaged` context.
    /// @unchecked Sendable: the Unmanaged box is exclusively owned by this
    /// lease from install until release, mirroring the teardown-request
    /// transport.
    final class Lease: TerminalByteTeeLease, @unchecked Sendable {
        private let context: Unmanaged<TerminalOutputTeeContext>

        init(context: Unmanaged<TerminalOutputTeeContext>) {
            self.context = context
        }

        func release() {
            context.release()
        }
    }

    @MainActor
    func prepareTee(
        workspaceID: UUID,
        surfaceID: UUID,
        surfaceGeneration: UInt64
    ) -> TerminalByteTeeInstallation {
        let teeContext = Unmanaged.passRetained(TerminalOutputTeeContext(
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            surfaceGeneration: surfaceGeneration,
            renderWorker: renderWorker,
            agentDefinitions: CmuxTaskManagerCodingAgentDefinition.builtIns
        ))
        return TerminalByteTeeInstallation(
            callback: cmuxTerminalOutputTeeCallback,
            userdata: teeContext.toOpaque(),
            lease: Lease(context: teeContext)
        )
    }

    @MainActor
    func dropSurface(surfaceID: UUID) {
        MobileTerminalByteTee.shared.dropSurface(surfaceID: surfaceID)
    }
}

// MARK: Ghostty render worker

/// Process-wide bridge to the supervised AppKit-free Ghostty renderer.
final class GhosttyRenderRuntimeBridge: TerminalRenderWorkerRouting, @unchecked Sendable {
    static let shared = GhosttyRenderRuntimeBridge()

    private let client: GhosttyRenderWorkerClient?
    private let revisionLock = NSLock()
    private var nextConfigurationRevision: UInt64 = 1
    private var observationStarted = false

    private init() {
        do {
            client = try GhosttyRenderWorkerClient.bundledWorker()
        } catch {
            client = nil
            cmuxDebugLog("ghostty render worker unavailable: \(error)")
        }
    }

    func enqueueRenderCommand(_ command: TerminalRenderWorkerCommand) {
        client?.commandSink.enqueue(command)
    }

    func updateConfiguration(_ config: ghostty_config_t) {
        guard let client else { return }
        let serialized = ghostty_config_serialize(config)
        defer { ghostty_string_free(serialized) }
        guard let bytes = serialized.ptr else { return }
        let contents = String(
            decoding: UnsafeRawBufferPointer(start: bytes, count: Int(serialized.len)),
            as: UTF8.self
        )
        let state = revisionLock.withLock { () -> (revision: UInt64, startObservation: Bool) in
            defer { nextConfigurationRevision &+= 1 }
            let shouldStart = !observationStarted
            observationStarted = true
            return (nextConfigurationRevision, shouldStart)
        }
        let snapshot = TerminalRenderConfigurationSnapshot(
            revision: state.revision,
            contents: contents
        )
        if state.startObservation {
            Task {
                let events = await client.subscribeEvents()
                let frames = await client.subscribeFrames()
                await client.updateConfiguration(snapshot)
                async let eventObservation: Void = observeEvents(events)
                async let frameObservation: Void = observeFrames(frames)
                _ = await (eventObservation, frameObservation)
            }
        } else {
            Task { await client.updateConfiguration(snapshot) }
        }
    }

    private func observeEvents(
        _ events: AsyncStream<GhosttyRenderWorkerClientEvent>
    ) async {
        var activeWorkerGeneration: UInt64?
        for await event in events {
            switch event {
            case let .initialized(workerGeneration, _):
                activeWorkerGeneration = workerGeneration
                await MainActor.run {
                    for case let surface as TerminalSurface in GhosttyApp.terminalSurfaceRegistry.allSurfaces() {
                        surface.renderWorkerDidBecomeReady(workerGeneration: workerGeneration)
                    }
                }
            case let .surfaceCreated(surfaceID, _):
                guard let activeWorkerGeneration else { continue }
                await MainActor.run {
                    guard let surface = GhosttyApp.terminalSurfaceRegistry.surface(id: surfaceID)
                        as? TerminalSurface else { return }
                    surface.renderWorkerDidBecomeReady(workerGeneration: activeWorkerGeneration)
                }
            case let .resynchronizationRequired(surfaceID, surfaceGeneration):
                Task { @MainActor in
                    guard let surface = GhosttyApp.terminalSurfaceRegistry.surface(id: surfaceID)
                        as? TerminalSurface,
                        let command = await surface.renderWorkerResynchronizationCommand(
                            surfaceGeneration: surfaceGeneration
                        ) else { return }
                    self.enqueueRenderCommand(command)
                }
            case let .workerExited(workerGeneration):
                if activeWorkerGeneration == workerGeneration {
                    activeWorkerGeneration = nil
                }
                await MainActor.run {
                    for case let surface as TerminalSurface in GhosttyApp.terminalSurfaceRegistry.allSurfaces() {
                        surface.renderWorkerDidExit(workerGeneration: workerGeneration)
                    }
                }
            case .outputApplied:
                break
            case let .failure(message):
                cmuxDebugLog("ghostty render worker: \(message)")
            }
        }
    }

    private func observeFrames(_ frames: AsyncStream<TerminalRenderFrame>) async {
        for await frame in frames {
            await MainActor.run {
                guard let surface = GhosttyApp.terminalSurfaceRegistry
                    .surface(id: frame.metadata.surfaceID) as? TerminalSurface else { return }
                surface.acceptRenderWorkerFrame(frame)
            }
        }
    }
}

// MARK: Renderer reclamation

extension RendererRealizationController: TerminalRendererRealizationScheduling {}

// MARK: Agent hibernation

/// The legacy `recordAgentHibernationTerminalInput` free helper as an
/// injected recorder: same gate, same timestamp capture, same main-actor hop.
final class TerminalAgentHibernationRecorder: AgentHibernationRecording {
    func recordTerminalInput(workspaceId: UUID, panelId: UUID) {
        guard AgentHibernationTrackingGate.isEnabled() else { return }
        let recordedAt = Date()
        Task { @MainActor in
            AgentHibernationController.shared.recordTerminalInput(
                workspaceId: workspaceId,
                panelId: panelId,
                recordedAt: recordedAt
            )
        }
    }
}

// MARK: Filesystem

extension TerminalSurfaceRuntimeFilesystem {
    static func live() -> TerminalSurfaceRuntimeFilesystem {
        TerminalSurfaceRuntimeFilesystem(
            claudeCommandShimTemporaryDirectory: FileManager.default.temporaryDirectory,
            installClaudeCommandShim: {
                TerminalSurface.installClaudeCommandShimIfPossible(
                    wrapperURL: $0,
                    surfaceId: $1,
                    temporaryDirectory: $2,
                    fileManager: .default
                )
            },
            isExecutableFile: { FileManager.default.isExecutableFile(atPath: $0) }
        )
    }
}

// MARK: Construction

extension TerminalSurface {
    /// The legacy app-target initializer signature, forwarding to the package
    /// initializer with the process-wide collaborator bundle. Keeps every
    /// existing call site byte-identical while construction is injected
    /// (dissolves when a real composition root constructs surfaces).
    @MainActor
    convenience init(
        id: UUID = UUID(),
        tabId: UUID,
        context: ghostty_surface_context_e,
        configTemplate: CmuxSurfaceConfigTemplate?,
        workingDirectory: String? = nil,
        portOrdinal: Int = 0,
        initialCommand: String? = nil,
        tmuxStartCommand: String? = nil,
        initialInput: String? = nil,
        initialEnvironmentOverrides: [String: String] = [:],
        additionalEnvironment: [String: String] = [:],
        focusPlacement: TerminalSurfaceFocusPlacement = .workspace,
        manualIO: Bool = false,
        manualInputHandler: (@Sendable (Data) -> Void)? = nil,
        runtimeSpawnPolicy: TerminalSurfaceRuntimeSpawnPolicy = .immediate,
        preparePaneHost: @Sendable @MainActor (any TerminalSurfacePaneHosting) -> Void = { _ in }
    ) {
        self.init(
            id: id,
            tabId: tabId,
            context: context,
            configTemplate: configTemplate,
            workingDirectory: workingDirectory,
            portOrdinal: portOrdinal,
            initialCommand: initialCommand,
            tmuxStartCommand: tmuxStartCommand,
            initialInput: initialInput,
            initialEnvironmentOverrides: initialEnvironmentOverrides,
            additionalEnvironment: additionalEnvironment,
            focusPlacement: focusPlacement,
            manualIO: manualIO,
            manualInputHandler: manualInputHandler,
            runtimeSpawnPolicy: runtimeSpawnPolicy,
            preparePaneHost: preparePaneHost,
            dependencies: GhosttyApp.terminalSurfaceRuntimeDependencies
        )
    }
}
