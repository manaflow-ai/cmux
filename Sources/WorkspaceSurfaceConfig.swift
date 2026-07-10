import Foundation
import CmuxFoundation
import CmuxTerminalCore

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
}
