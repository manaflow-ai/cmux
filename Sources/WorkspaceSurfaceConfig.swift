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

@MainActor
func cmuxCurrentSurfaceFontSizePoints(_ surface: ghostty_surface_t) -> Float? {
    GhosttySurfaceRuntimeProbe.currentSurfaceFontSizePoints(surface)
}

@MainActor
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

    // Capture runtime zoom for inheritance, even when Ghostty's inherit-font-size
    // config is disabled, without claiming surface-local ownership.
    let runtimePoints = cmuxCurrentSurfaceFontSizePoints(sourceSurface)
    if let points = runtimePoints {
        config.setFontSize(
            CmuxSurfaceConfigTemplate.baseFontSize(
                fromRuntimePoints: points,
                percent: percent
            ),
            isExplicitOverride: false
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
    /// Adjusts every terminal owned by this workspace, including its Dock.
    ///
    /// Each surface retains its relative size. Deferred and hibernated surfaces
    /// receive the same point delta through their durable font-size lineage.
    @discardableResult
    func adjustTerminalFontSizes(byRuntimePoints deltaRuntimePoints: Float32) -> Int {
        guard deltaRuntimePoints.isFinite, deltaRuntimePoints != 0 else { return 0 }

        var terminalPanels = panels.values.compactMap { $0 as? TerminalPanel }
        if let dock = _dockSplit {
            terminalPanels.append(contentsOf: dock.panels.values.compactMap { $0 as? TerminalPanel })
        }

        var seenPanelIds: Set<UUID> = []
        terminalPanels = terminalPanels
            .filter { seenPanelIds.insert($0.id).inserted }
            .sorted { $0.id.uuidString < $1.id.uuidString }

        let configuredRuntimePoints = Float32(
            GhosttyConfig.load(
                globalFontMagnificationPercent: GlobalFontMagnification.storedPercent
            ).fontSize
        )
        var adjustedCount = 0
        for terminalPanel in terminalPanels where terminalPanel.surface.adjustFontSize(
            byRuntimePoints: deltaRuntimePoints,
            fallbackRuntimePoints: configuredRuntimePoints
        ) {
            adjustedCount += 1
        }

        if let rememberedTerminalPanel = lastRememberedTerminalPanelForConfigInheritance() {
            rememberTerminalConfigInheritanceSource(rememberedTerminalPanel)
        }
        return adjustedCount
    }
}
