import Foundation
import CmuxFoundation
import CmuxTerminalCore

// CmuxSurfaceConfigTemplate and the surface runtime probes moved to
// CmuxTerminalCore (SurfaceValues/CmuxSurfaceConfigTemplate.swift and
// Interop/GhosttySurfaceRuntimeProbe.swift). The legacy free-function names
// below are shims forwarding existing app callers to the probe.

typealias CmuxSurfaceConfigTemplate = CmuxTerminalCore.CmuxSurfaceConfigTemplate

enum WorkspaceTerminalFontSizeChange: Equatable {
    case relative([Float32])
    case resetThen([Float32])

    var isNoOp: Bool {
        if case .relative(let runs) = self {
            return runs.isEmpty
        }
        return false
    }

    var nativeActionUpperBoundPerLiveSurface: Int {
        switch self {
        case .relative:
            return 1
        case .resetThen(let runs):
            return runs.isEmpty ? 1 : 2
        }
    }

    mutating func appendAdjustment(_ deltaRuntimePoints: Float32) {
        guard deltaRuntimePoints.isFinite, deltaRuntimePoints != 0 else { return }
        switch self {
        case .relative(var runs):
            Self.append(deltaRuntimePoints, to: &runs)
            self = .relative(runs)
        case .resetThen(var runs):
            Self.append(deltaRuntimePoints, to: &runs)
            self = .resetThen(runs)
        }
    }

    mutating func appendReset() {
        self = .resetThen([])
    }

    private static func append(_ deltaRuntimePoints: Float32, to runs: inout [Float32]) {
        if let last = runs.last,
           (last > 0) == (deltaRuntimePoints > 0) {
            runs[runs.count - 1] = last + deltaRuntimePoints
        } else {
            runs.append(deltaRuntimePoints)
        }
    }
}

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
        adjustTerminalFontSizes(
            byOrderedRuntimePointDeltas: [deltaRuntimePoints],
            additionalTerminalPanels: additionalTerminalPanels
        )
    }

    /// Applies ordered, same-direction runs to every terminal while each
    /// surface reduces them against its own native bounds.
    @discardableResult
    func adjustTerminalFontSizes(
        byOrderedRuntimePointDeltas orderedRuntimePointDeltas: [Float32],
        additionalTerminalPanels: [TerminalPanel] = []
    ) -> Int {
        performTerminalFontSizeChange(
            .relative(orderedRuntimePointDeltas),
            additionalTerminalPanels: additionalTerminalPanels
        )
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
        performTerminalFontSizeChange(
            .resetThen([]),
            additionalTerminalPanels: additionalTerminalPanels
        )
    }

    @discardableResult
    func performTerminalFontSizeChange(
        _ change: WorkspaceTerminalFontSizeChange,
        additionalTerminalPanels: [TerminalPanel] = []
    ) -> Int {
        guard !change.isNoOp else { return 0 }
        let terminalPanels = terminalPanelsForFontSizeChange(
            additionalTerminalPanels: additionalTerminalPanels
        )
        let configuredRuntimePoints = configuredTerminalRuntimeFontSize()
        var changedTerminalPanels: [TerminalPanel] = []
        for terminalPanel in terminalPanels {
            if applyTerminalFontSizeChange(
                change,
                to: terminalPanel,
                configuredRuntimePoints: configuredRuntimePoints
            ) {
                changedTerminalPanels.append(terminalPanel)
            }
        }

        completeTerminalFontSizeChange(
            change,
            changedTerminalPanels: changedTerminalPanels,
            configuredRuntimePoints: configuredRuntimePoints
        )
        return changedTerminalPanels.count
    }

    func terminalPanelsForFontSizeChange(
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

    func configuredTerminalRuntimeFontSize() -> Float32 {
        Float32(
            GhosttyConfig.load(
                globalFontMagnificationPercent: GlobalFontMagnification.storedPercent
            ).fontSize
        )
    }

    @discardableResult
    func applyTerminalFontSizeChange(
        _ change: WorkspaceTerminalFontSizeChange,
        to terminalPanel: TerminalPanel,
        configuredRuntimePoints: Float32
    ) -> Bool {
        switch change {
        case .relative(let runs):
            return terminalPanel.surface.adjustFontSize(
                byOrderedRuntimePointDeltas: runs,
                fallbackRuntimePoints: configuredRuntimePoints
            )
        case .resetThen(let runs):
            let didReset = terminalPanel.surface.resetFontSize(
                toConfiguredRuntimePoints: configuredRuntimePoints
            )
            guard !runs.isEmpty else { return didReset }
            let didAdjust = terminalPanel.surface.adjustFontSize(
                byOrderedRuntimePointDeltas: runs,
                fallbackRuntimePoints: configuredRuntimePoints
            )
            return didReset || didAdjust
        }
    }

    func completeTerminalFontSizeChange(
        _ change: WorkspaceTerminalFontSizeChange,
        changedTerminalPanels: [TerminalPanel],
        configuredRuntimePoints: Float32
    ) {
        refreshTerminalFontSizeInheritanceSource(
            changedTerminalPanels: changedTerminalPanels
        )
        if case .resetThen(let runs) = change {
            rememberTerminalFontSizeLineageForConfigInheritance(
                configuredTerminalFontSizeLineage(
                    configuredRuntimePoints: configuredRuntimePoints,
                    applying: runs
                )
            )
        }
        _dockSplit?.rememberTerminalFontSizeLineageForNewTerminals(
            fallback: lastRememberedTerminalFontSizeLineageForConfigInheritance()
        )
    }

    private func configuredTerminalFontSizeLineage(
        configuredRuntimePoints: Float32,
        applying orderedRuntimePointDeltas: [Float32] = []
    ) -> TerminalFontSizeLineage {
        let policy = TerminalFontSizePolicy()
        let configuredRuntimePoints = policy.clampedRuntimePoints(
            configuredRuntimePoints
        )
        let finalRuntimePoints = orderedRuntimePointDeltas.reduce(
            configuredRuntimePoints
        ) { current, delta in
            policy.clampedRuntimePoints(current + delta)
        }
        return TerminalFontSizeLineage(
            basePoints: CmuxSurfaceConfigTemplate.baseFontSize(
                fromRuntimePoints: finalRuntimePoints,
                percent: GlobalFontMagnification.storedPercent
            ),
            isExplicitOverride: finalRuntimePoints != configuredRuntimePoints
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
        if let fallbackTerminalPanel = changedTerminalPanels.first,
           let fallbackLineage = fallbackTerminalPanel.surface.fontSizeLineageSnapshot() {
            rememberTerminalFontSizeLineageForConfigInheritance(fallbackLineage)
        }
    }
}
