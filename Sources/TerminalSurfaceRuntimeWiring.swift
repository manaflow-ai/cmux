import AppKit
import Foundation
import CmuxTerminal
import CmuxTerminalCore
import GhosttyKit
import CmuxSettings
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
            claudeHooksEnabled: integrations.claudeCodeHooksEnabled,
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

// MARK: Mobile byte tee

/// Installs the libghostty PTY tee for `MobileTerminalByteTee` and keys
/// drop/replay state by surface id (the legacy inline
/// `ghostty_surface_set_pty_tee_cb` + `MobileTerminalByteTee.shared` calls).
final class TerminalMobileByteTeeBridge: TerminalByteTeeBinding {
    /// Wraps the retained tee userdata; `release()` runs exactly where the
    /// surface released the legacy `Unmanaged` context.
    /// @unchecked Sendable: the Unmanaged box is exclusively owned by this
    /// lease from install until release, mirroring the teardown-request
    /// transport.
    final class Lease: TerminalByteTeeLease, @unchecked Sendable {
        private let context: Unmanaged<MobileTerminalByteTeeUserdata>

        init(context: Unmanaged<MobileTerminalByteTeeUserdata>) {
            self.context = context
        }

        func release() {
            context.release()
        }
    }

    @MainActor
    func installTee(on surface: ghostty_surface_t, surfaceID: UUID) -> any TerminalByteTeeLease {
        let teeContext = Unmanaged.passRetained(MobileTerminalByteTeeUserdata(surfaceID: surfaceID))
        ghostty_surface_set_pty_tee_cb(
            surface,
            cmuxMobileTerminalByteTeeCallback,
            teeContext.toOpaque()
        )
        return Lease(context: teeContext)
    }

    @MainActor
    func dropSurface(surfaceID: UUID) {
        MobileTerminalByteTee.shared.dropSurface(surfaceID: surfaceID)
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
        runtimeSpawnPolicy: TerminalSurfaceRuntimeSpawnPolicy = .immediate
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
            dependencies: GhosttyApp.terminalSurfaceRuntimeDependencies
        )
    }
}
