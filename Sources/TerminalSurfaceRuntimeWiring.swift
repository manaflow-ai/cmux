import AppKit
import Foundation
import CmuxTerminal
import CmuxTerminalCore
import GhosttyKit
import CmuxSettings
import struct CmuxSettings.AgentIntegrationSettingsStore
import CmuxTerminalRenderer
import IOSurface
import QuartzCore
import XPC
import os

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
    private let rendererService: RendererWorkspaceMirrorService

    init(bundle: Bundle = .main) {
        let helperURL = bundle.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent("CmuxTerminalRendererWorker", isDirectory: false)
        rendererService = RendererWorkspaceMirrorService(helperURL: helperURL)
    }

    /// Wraps the retained tee userdata; `release()` runs exactly where the
    /// surface released the legacy `Unmanaged` context.
    /// @unchecked Sendable: the Unmanaged box is exclusively owned by this
    /// lease from install until release, mirroring the teardown-request
    /// transport.
    final class Lease: TerminalByteTeeLease, @unchecked Sendable {
        private let context: Unmanaged<TerminalOutputTeeContext>
        private let rendererService: RendererWorkspaceMirrorService
        private let outputRelay: RendererProcessOutputRelay
        private weak var owner: TerminalSurface?
        private weak var view: (any TerminalSurfaceNativeViewing)?
        private let lock = OSAllocatedUnfairLock(initialState: State())

        private struct State {
            var released = false
            var mirror: RendererSurfaceMirror?
            var registered = false
            var registrationTask: Task<Void, Never>?
            var lastAcceptedFrame: RendererFrameMetadata?
        }

        @MainActor
        init(
            context: Unmanaged<TerminalOutputTeeContext>,
            rendererService: RendererWorkspaceMirrorService,
            outputRelay: RendererProcessOutputRelay,
            owner: TerminalSurface,
            view: any TerminalSurfaceNativeViewing
        ) {
            self.context = context
            self.rendererService = rendererService
            self.outputRelay = outputRelay
            self.owner = owner
            self.view = view
        }

        func release() {
            let releaseState: (Task<Void, Never>?, RendererSurfaceMirror?)? = lock.withLock { state in
                guard !state.released else { return nil }
                state.released = true
                let result = (
                    state.registrationTask,
                    state.registered ? state.mirror : nil
                )
                state.registrationTask = nil
                state.mirror = nil
                return result
            }
            guard let releaseState else { return }
            releaseState.0?.cancel()
            context.release()
            let rendererService = rendererService
            let mirror = releaseState.1
            Task { @MainActor [weak owner, weak view] in
                if let owner {
                    view?.layer?.contents = nil
                    owner.deactivateExternalRenderer()
                }
                if let mirror {
                    await rendererService.unregister(mirror)
                }
            }
        }

        @MainActor
        func start(configuration: RendererSurfaceConfiguration) {
            let rendererService = rendererService
            let mirror = rendererService.makeMirror(
                configuration: configuration,
                outputRelay: outputRelay
            )
            let canStart = lock.withLock { state -> Bool in
                guard !state.released else { return false }
                state.mirror = mirror
                return true
            }
            guard canStart else {
                Task { await rendererService.unregister(mirror) }
                return
            }
            let task = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await rendererService.register(
                        configuration: configuration,
                        mirror: mirror
                    )
                    let shouldRun = lock.withLock { state -> Bool in
                        guard !state.released else { return false }
                        state.registered = true
                        return true
                    }
                    guard shouldRun else {
                        await rendererService.unregister(mirror)
                        return
                    }
                    for await event in mirror.events {
                        if Task.isCancelled { break }
                        if RendererIPCMessage.operation(in: event.value) == .processExited {
                            restoreLocalRenderer()
                        } else {
                            presentFrameIfCurrent(event, mirror: mirror)
                        }
                    }
                    lock.withLock { state in
                        if state.mirror === mirror {
                            state.mirror = nil
                            state.registered = false
                        }
                    }
                    if !Task.isCancelled {
                        restoreLocalRenderer()
                    }
                } catch {
                    lock.withLock { state in
                        if state.mirror === mirror {
                            state.mirror = nil
                            state.registered = false
                        }
                    }
                    restoreLocalRenderer()
                }
            }
            lock.withLock { state in
                if state.released {
                    task.cancel()
                } else {
                    state.registrationTask = task
                }
            }
        }

        @MainActor
        private func presentFrameIfCurrent(
            _ event: RendererXPCObject,
            mirror: RendererSurfaceMirror
        ) {
            guard RendererIPCMessage.operation(in: event.value) == .frame,
                  let owner, let view,
                  owner.id == mirror.identity.surfaceID,
                  let surfaceObject = xpc_dictionary_get_value(
                    event.value,
                    RendererIPCKey.ioSurface
                  ), let ioSurface = IOSurfaceLookupFromXPCObject(surfaceObject) else { return }
            let sequence = xpc_dictionary_get_uint64(event.value, RendererIPCKey.sequence)
            let generation = xpc_dictionary_get_uint64(event.value, RendererIPCKey.generation)
            let frame = RendererFrameMetadata(
                identity: RendererSurfaceIdentity(
                    workspaceID: mirror.identity.workspaceID,
                    surfaceID: mirror.identity.surfaceID,
                    generation: generation
                ),
                sequence: sequence,
                pixelWidth: Int(xpc_dictionary_get_uint64(event.value, RendererIPCKey.width)),
                pixelHeight: Int(xpc_dictionary_get_uint64(event.value, RendererIPCKey.height)),
                scaleX: xpc_dictionary_get_double(event.value, RendererIPCKey.scaleX),
                scaleY: xpc_dictionary_get_double(event.value, RendererIPCKey.scaleY)
            )
            let accepted = lock.withLock { state -> Bool in
                guard !state.released,
                      RendererFrameAcceptance.accepts(
                          frame,
                          currentGeneration: mirror.identity.generation,
                          lastAccepted: state.lastAcceptedFrame
                      ) else { return false }
                state.lastAcceptedFrame = frame
                return true
            }
            guard accepted else { return }

            if !owner.externalRendererIsActive {
                guard owner.activateExternalRenderer() else { return }
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            view.layer?.contents = ioSurface
            view.layer?.contentsScale = max(
                1,
                frame.scaleX
            )
            CATransaction.commit()
        }

        @MainActor
        private func restoreLocalRenderer() {
            view?.layer?.contents = nil
            owner?.deactivateExternalRenderer()
        }

        @MainActor
        func updateRendererSize(
            pixelWidth: UInt32,
            pixelHeight: UInt32,
            scaleX: Double,
            scaleY: Double
        ) {
            guard let mirror = lock.withLock({ $0.mirror }) else { return }
            mirror.resize(
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight,
                scaleX: scaleX,
                scaleY: scaleY
            )
        }

        func updateRendererFocus(_ focused: Bool) {
            guard let mirror = lock.withLock({ $0.mirror }) else { return }
            mirror.send(RendererIPCCommand.focus(identity: mirror.identity, focused: focused))
        }

        func updateRendererOcclusion(_ visible: Bool) {
            guard let mirror = lock.withLock({ $0.mirror }) else { return }
            let message = RendererIPCCommand.surface(operation: .occlusion, identity: mirror.identity)
            xpc_dictionary_set_bool(message, RendererIPCKey.value, visible)
            mirror.send(RendererXPCObject(message))
        }

        func sendRendererMousePosition(x: Double, y: Double, modifiers: UInt32) {
            guard let mirror = lock.withLock({ $0.mirror }) else { return }
            mirror.send(RendererIPCCommand.mousePosition(
                identity: mirror.identity,
                x: x,
                y: y,
                modifiers: modifiers
            ))
        }

        func sendRendererMouseButton(state: UInt32, button: UInt32, modifiers: UInt32) {
            guard let mirror = lock.withLock({ $0.mirror }) else { return }
            mirror.send(RendererIPCCommand.mouseButton(
                identity: mirror.identity,
                state: state,
                button: button,
                modifiers: modifiers
            ))
        }

        func sendRendererMouseScroll(x: Double, y: Double, packedModifiers: Int32) {
            guard let mirror = lock.withLock({ $0.mirror }) else { return }
            mirror.send(RendererIPCCommand.mouseScroll(
                identity: mirror.identity,
                x: x,
                y: y,
                packedModifiers: packedModifiers
            ))
        }

        func sendRendererMousePressure(stage: UInt32, pressure: Double) {
            guard let mirror = lock.withLock({ $0.mirror }) else { return }
            mirror.send(RendererIPCCommand.mousePressure(
                identity: mirror.identity,
                stage: stage,
                pressure: pressure
            ))
        }

        func sendRendererKey(_ event: ghostty_input_key_s) {
            guard let mirror = lock.withLock({ $0.mirror }) else { return }
            mirror.send(RendererIPCCommand.key(
                identity: mirror.identity,
                action: event.action.rawValue,
                modifiers: event.mods.rawValue,
                consumedModifiers: event.consumed_mods.rawValue,
                keycode: event.keycode,
                textPointer: event.text,
                unshiftedCodepoint: event.unshifted_codepoint,
                composing: event.composing
            ))
        }

        func sendRendererText(_ text: String, marked: Bool) {
            guard let mirror = lock.withLock({ $0.mirror }) else { return }
            mirror.send(RendererIPCCommand.text(
                identity: mirror.identity,
                text: text,
                marked: marked
            ))
        }

        func sendRendererUnmarkText() {
            guard let mirror = lock.withLock({ $0.mirror }) else { return }
            mirror.send(RendererXPCObject(RendererIPCCommand.surface(
                operation: .unmarkText,
                identity: mirror.identity
            )))
        }

        func sendRendererBindingAction(_ action: String) {
            guard let mirror = lock.withLock({ $0.mirror }) else { return }
            mirror.send(RendererIPCCommand.bindingAction(
                identity: mirror.identity,
                action: action
            ))
        }

        func updateRendererColorScheme(_ rawValue: UInt32) {
            guard let mirror = lock.withLock({ $0.mirror }) else { return }
            let message = RendererIPCCommand.surface(
                operation: .updateConfiguration,
                identity: mirror.identity
            )
            xpc_dictionary_set_uint64(message, RendererIPCKey.flags, 1)
            xpc_dictionary_set_uint64(message, RendererIPCKey.value, UInt64(rawValue))
            mirror.send(RendererXPCObject(message))
        }

        func reloadRendererConfiguration() {
            guard let mirror = lock.withLock({ $0.mirror }) else { return }
            let message = RendererIPCCommand.surface(
                operation: .updateConfiguration,
                identity: mirror.identity
            )
            xpc_dictionary_set_uint64(message, RendererIPCKey.flags, 2)
            mirror.send(RendererXPCObject(message))
        }
    }

    @MainActor
    func installTee(
        on surface: ghostty_surface_t,
        owner: TerminalSurface,
        view: any TerminalSurfaceNativeViewing,
        workspaceID: UUID,
        surfaceID: UUID,
        pixelWidth: UInt32,
        pixelHeight: UInt32,
        scaleX: Double,
        scaleY: Double,
        fontSize: Float,
        context: UInt32
    ) -> any TerminalByteTeeLease {
        let outputRelay = RendererProcessOutputRelay()
        let teeContext = Unmanaged.passRetained(TerminalOutputTeeContext(
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            agentDefinitions: CmuxTaskManagerCodingAgentDefinition.builtIns,
            rendererOutputRelay: outputRelay
        ))
        ghostty_surface_set_pty_tee_cb(
            surface,
            cmuxTerminalOutputTeeCallback,
            teeContext.toOpaque()
        )
        let lease = Lease(
            context: teeContext,
            rendererService: rendererService,
            outputRelay: outputRelay,
            owner: owner,
            view: view
        )
        lease.start(configuration: RendererSurfaceConfiguration(
            identity: RendererSurfaceIdentity(
                workspaceID: workspaceID,
                surfaceID: surfaceID,
                generation: 1
            ),
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            scaleX: scaleX,
            scaleY: scaleY,
            fontSize: fontSize,
            workingDirectory: nil,
            command: nil,
            initialInput: nil,
            environment: [:],
            waitAfterCommand: false,
            context: context,
            manualIO: true
        ))
        return lease
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
