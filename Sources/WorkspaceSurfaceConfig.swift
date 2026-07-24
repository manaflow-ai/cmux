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
    /// Adjusts every terminal owned by this workspace, including nested remote
    /// tmux mirrors, its legacy per-workspace Dock, and any window-owned panels
    /// supplied by the shortcut router.
    ///
    /// Each surface retains its relative size. Deferred and hibernated surfaces
    /// receive the same point delta through their durable font-size lineage.
    @discardableResult
    func adjustTerminalFontSizes(
        byRuntimePoints deltaRuntimePoints: Float32,
        additionalTerminalPanels: [TerminalPanel] = []
    ) -> Int {
        guard deltaRuntimePoints.isFinite, deltaRuntimePoints != 0 else { return 0 }

        let terminalPanels = terminalPanelsForFontSizeChange(
            additionalTerminalPanels: additionalTerminalPanels
        )
        let configuredRuntimePoints = configuredTerminalRuntimeFontSize()
        var adjustedCount = 0
        var adjustedTerminalPanels: [TerminalPanel] = []
        for terminalPanel in terminalPanels {
            if terminalPanel.surface.adjustFontSize(
                byRuntimePoints: deltaRuntimePoints,
                fallbackRuntimePoints: configuredRuntimePoints
            ) {
                adjustedCount += 1
                adjustedTerminalPanels.append(terminalPanel)
            }
        }

        refreshTerminalFontSizeInheritanceSource(
            changedTerminalPanels: adjustedTerminalPanels
        )
        return adjustedCount
    }

    /// Resets every terminal owned by this workspace to current Ghostty config.
    ///
    /// - Parameter additionalTerminalPanels: Window-owned Dock terminals that
    ///   belong to this workspace but are not stored in its panel collections.
    /// - Returns: Number of live or durable terminal surfaces reset.
    @discardableResult
    func resetTerminalFontSizes(
        additionalTerminalPanels: [TerminalPanel] = []
    ) -> Int {
        let terminalPanels = terminalPanelsForFontSizeChange(
            additionalTerminalPanels: additionalTerminalPanels
        )
        let configuredRuntimePoints = configuredTerminalRuntimeFontSize()
        var resetCount = 0
        var resetTerminalPanels: [TerminalPanel] = []
        for terminalPanel in terminalPanels {
            if terminalPanel.surface.resetFontSize(
                toConfiguredRuntimePoints: configuredRuntimePoints
            ) {
                resetCount += 1
                resetTerminalPanels.append(terminalPanel)
            }
        }

        refreshTerminalFontSizeInheritanceSource(
            changedTerminalPanels: resetTerminalPanels
        )
        return resetCount
    }

    private func terminalPanelsForFontSizeChange(
        additionalTerminalPanels: [TerminalPanel]
    ) -> [TerminalPanel] {
        var terminalPanels = panels.values.compactMap { $0 as? TerminalPanel }
        if let dock = _dockSplit {
            terminalPanels.append(contentsOf: dock.panels.values.compactMap { $0 as? TerminalPanel })
        }
        for mirror in remoteTmuxWindowMirrors.values {
            terminalPanels.append(contentsOf: mirror.panelsByPaneId.values)
        }
        terminalPanels.append(contentsOf: additionalTerminalPanels)

        var seenPanelIds: Set<UUID> = []
        return terminalPanels
            .filter { seenPanelIds.insert($0.id).inserted }
            .sorted { $0.id.uuidString < $1.id.uuidString }
    }

    private func configuredTerminalRuntimeFontSize() -> Float32 {
        Float32(
            GhosttyConfig.load(
                globalFontMagnificationPercent: GlobalFontMagnification.storedPercent
            ).fontSize
        )
    }

    private func refreshTerminalFontSizeInheritanceSource(
        changedTerminalPanels: [TerminalPanel]
    ) {
        if let mainTerminalPanel =
            lastRememberedTerminalPanelForConfigInheritance()
                ?? terminalPanelForConfigInheritance() {
            rememberTerminalConfigInheritanceSource(mainTerminalPanel)
            return
        }
        if let fallbackTerminalPanel = changedTerminalPanels.first {
            rememberTerminalFontSizeLineageForConfigInheritance(fallbackTerminalPanel)
        }
    }
}
