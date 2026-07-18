import CmuxTerminal
import CmuxTerminalCore
import Foundation
import GhosttyKit

/// The complete, behavior-preserving input to terminal panel construction.
///
/// `origin` is diagnostic routing metadata for the backend seam. It does not
/// select an implementation or change terminal behavior.
@MainActor
struct TerminalPanelCreationRequest {
    enum Origin: String, Equatable, Sendable {
        case legacyDirect
        case workspaceInitial
        case workspaceTab
        case workspaceSplit
        case sessionRestore
        case cloudVMReplacement
        case workspaceRespawn
        case workspaceReplacement
        case remoteTmuxMirror
        case workspaceSplitRepair
        case dock
    }

    let origin: Origin
    let id: UUID
    let workspaceId: UUID
    let context: ghostty_surface_context_e
    let configTemplate: CmuxSurfaceConfigTemplate?
    let workingDirectory: String?
    let portOrdinal: Int
    let initialCommand: String?
    let tmuxStartCommand: String?
    let initialInput: String?
    let initialEnvironmentOverrides: [String: String]
    let additionalEnvironment: [String: String]
    let focusPlacement: TerminalSurfaceFocusPlacement
    let manualIO: Bool
    let manualInputHandler: (@Sendable (Data) -> Void)?
    let runtimeSpawnPolicy: TerminalSurfaceRuntimeSpawnPolicy

    init(
        origin: Origin,
        id: UUID = UUID(),
        workspaceId: UUID,
        context: ghostty_surface_context_e = GHOSTTY_SURFACE_CONTEXT_SPLIT,
        configTemplate: CmuxSurfaceConfigTemplate? = nil,
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
        self.origin = origin
        self.id = id
        self.workspaceId = workspaceId
        self.context = context
        self.configTemplate = configTemplate
        self.workingDirectory = workingDirectory
        self.portOrdinal = portOrdinal
        self.initialCommand = initialCommand
        self.tmuxStartCommand = tmuxStartCommand
        self.initialInput = initialInput
        self.initialEnvironmentOverrides = initialEnvironmentOverrides
        self.additionalEnvironment = additionalEnvironment
        self.focusPlacement = focusPlacement
        self.manualIO = manualIO
        self.manualInputHandler = manualInputHandler
        self.runtimeSpawnPolicy = runtimeSpawnPolicy
    }
}
