import Foundation
import CmuxFoundation
import CmuxTerminalCore
import CmuxWorkspaces

// CmuxSurfaceConfigTemplate and the surface runtime probes moved to
// CmuxTerminalCore (SurfaceValues/CmuxSurfaceConfigTemplate.swift and
// Interop/GhosttySurfaceRuntimeProbe.swift). The legacy free-function names
// below are shims forwarding existing app callers to the probe.

typealias CmuxSurfaceConfigTemplate = CmuxTerminalCore.CmuxSurfaceConfigTemplate

func cmuxSurfaceContextName(_ context: ghostty_surface_context_e) -> String {
    GhosttySurfaceRuntimeProbe.contextName(context)
}

func cmuxSurfacePointerAppearsLive(_ surface: ghostty_surface_t) -> Bool {
    GhosttySurfaceRuntimeProbe.surfacePointerAppearsLive(surface)
}

func cmuxCurrentSurfaceFontSizePoints(_ surface: ghostty_surface_t) -> Float? {
    GhosttySurfaceRuntimeProbe.currentSurfaceFontSizePoints(surface)
}

func cmuxInheritedSurfaceConfig(
    sourceSurface: ghostty_surface_t,
    context: ghostty_surface_context_e
) -> CmuxSurfaceConfigTemplate {
    let inherited = ghostty_surface_inherited_config(sourceSurface, context)
    let percent = GlobalFontMagnification.storedPercent
    var config = CmuxSurfaceConfigTemplate(
        cConfig: inherited,
        globalFontMagnificationPercent: percent
    )

    // Make runtime zoom inheritance explicit, even when Ghostty's
    // inherit-font-size config is disabled.
    let runtimePoints = cmuxCurrentSurfaceFontSizePoints(sourceSurface)
    if let points = runtimePoints {
        config.fontSize = CmuxSurfaceConfigTemplate.baseFontSize(
            fromRuntimePoints: points,
            percent: percent
        )
    }

#if DEBUG
    let inheritedText = String(format: "%.2f", inherited.font_size)
    let runtimeText = runtimePoints.map { String(format: "%.2f", $0) } ?? "nil"
    let finalText = String(format: "%.2f", config.fontSize)
    cmuxDebugLog(
        "zoom.inherit context=\(cmuxSurfaceContextName(context)) " +
        "inherited=\(inheritedText) runtime=\(runtimeText) final=\(finalText)"
    )
#endif

    return config
}

extension Workspace {
    nonisolated static func terminalStartupConfigTemplate(
        _ inheritedConfig: CmuxSurfaceConfigTemplate?,
        waitAfterCommand: Bool = false,
        clearWorkingDirectory: Bool = false
    ) -> CmuxSurfaceConfigTemplate? {
        guard waitAfterCommand || inheritedConfig != nil else { return nil }
        var template = inheritedConfig ?? CmuxSurfaceConfigTemplate()
        if waitAfterCommand {
            template.waitAfterCommand = true
        }
        if clearWorkingDirectory {
            template.workingDirectory = nil
        }
        return template
    }

    nonisolated static func terminalStartupInheritedWorkingDirectoryCandidate(
        _ inheritedWorkingDirectory: String?,
        shellActivityState: PanelShellActivityState?,
        isRemoteTerminalSurface: Bool,
        isRestoreGuarded: Bool,
        isAgentResumePendingOrRunning: Bool
    ) -> String? {
        guard shellActivityState == .promptIdle,
              !isRemoteTerminalSurface,
              !isRestoreGuarded,
              !isAgentResumePendingOrRunning else { return nil }
        return normalizedTerminalWorkingDirectory(inheritedWorkingDirectory)
    }

    func terminalStartupCandidateWorkingDirectory(
        _ workingDirectory: String?,
        sourcePanelId: UUID?
    ) -> String? {
        guard let sourcePanelId else { return nil }
        return Self.terminalStartupInheritedWorkingDirectoryCandidate(
            workingDirectory,
            shellActivityState: panelShellActivityStates[sourcePanelId],
            isRemoteTerminalSurface: isRemoteTerminalSurface(sourcePanelId),
            isRestoreGuarded: hasRestoredGuardedWorkingDirectory(panelId: sourcePanelId),
            isAgentResumePendingOrRunning: restoredAgentResumeStatesByPanelId[sourcePanelId] == .awaitingAutoResumeCommand ||
                restoredAgentResumeStatesByPanelId[sourcePanelId] == .autoResumeCommandRunning
        )
    }

    func liveForegroundWorkingDirectoryForTerminalStartup(sourcePanelId: UUID?) -> String? {
        guard let sourcePanelId else { return nil }
        guard Self.normalizedTerminalWorkingDirectory(panelDirectories[sourcePanelId]) == nil else { return nil }
        return terminalStartupCandidateWorkingDirectory(
            liveForegroundProcessWorkingDirectory(panelId: sourcePanelId),
            sourcePanelId: sourcePanelId
        )
    }

    func panelDirectoryForTerminalStartup(sourcePanelId: UUID?) -> String? {
        guard let sourcePanelId, !isRemoteTerminalSurface(sourcePanelId) else { return nil }
        return panelDirectories[sourcePanelId]
    }

    func currentDirectoryForTerminalStartup(sourcePanelId: UUID?) -> String? {
        guard !usesRemoteDirectoryProvenance else {
            return Self.safeLocalTerminalStartupWorkingDirectory()
        }
        guard sourcePanelId.map({ isRemoteTerminalSurface($0) }) != true else {
            return Self.safeLocalTerminalStartupWorkingDirectory()
        }
        return currentDirectory
    }

    nonisolated static func safeLocalTerminalStartupWorkingDirectory() -> String {
        normalizedTerminalWorkingDirectory(FileManager.default.homeDirectoryForCurrentUser.path) ?? NSHomeDirectory()
    }

    func inheritedTerminalWorkingDirectory(fromPanelId panelId: UUID?) -> String? {
        guard let panelId, let terminalPanel = terminalPanel(for: panelId) else { return nil }
        let surface = terminalPanel.surface
        guard let sourceSurface = surface.surface else { return nil }
        let config = cmuxInheritedSurfaceConfig(
            sourceSurface: sourceSurface,
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT
        )
        withExtendedLifetime((terminalPanel, surface)) {}
        return config.workingDirectory
    }
}
