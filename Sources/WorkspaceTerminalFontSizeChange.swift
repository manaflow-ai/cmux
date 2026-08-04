import Foundation
import CmuxFoundation
import CmuxTerminal
import CmuxTerminalCore

enum WorkspaceTerminalFontSizeChange: Equatable {
    case relative(TerminalFontSizeDeltaTransform)
    case resetThen(TerminalFontSizeDeltaTransform)

    static func relative(
        _ orderedRuntimePointDeltas: [Float32]
    ) -> WorkspaceTerminalFontSizeChange {
        guard orderedRuntimePointDeltas.allSatisfy(\.isFinite) else {
            return .relative(TerminalFontSizeDeltaTransform())
        }
        return .relative(
            TerminalFontSizeDeltaTransform(
                orderedRuntimePointDeltas: orderedRuntimePointDeltas
            )
        )
    }

    static func resetThen(
        _ orderedRuntimePointDeltas: [Float32]
    ) -> WorkspaceTerminalFontSizeChange {
        guard orderedRuntimePointDeltas.allSatisfy(\.isFinite) else {
            return .resetThen(TerminalFontSizeDeltaTransform())
        }
        return .resetThen(
            TerminalFontSizeDeltaTransform(
                orderedRuntimePointDeltas: orderedRuntimePointDeltas
            )
        )
    }

    var isNoOp: Bool {
        if case .relative(let transform) = self {
            return transform.isIdentity
        }
        return false
    }

    var nativeActionUpperBoundPerLiveSurface: Int {
        switch self {
        case .relative:
            return 1
        case .resetThen(let transform):
            return transform.isIdentity ? 1 : 2
        }
    }

    mutating func appendAdjustment(_ deltaRuntimePoints: Float32) {
        guard deltaRuntimePoints.isFinite, deltaRuntimePoints != 0 else { return }
        switch self {
        case .relative(var transform):
            transform.append(deltaRuntimePoints)
            self = .relative(transform)
        case .resetThen(var transform):
            transform.append(deltaRuntimePoints)
            self = .resetThen(transform)
        }
    }

    mutating func appendReset() {
        self = .resetThen([])
    }

    func resultingInheritanceLineage(
        from sourceLineage: TerminalFontSizeLineage?,
        configuredRuntimePoints: Float32,
        magnificationPercent: Int
    ) -> TerminalFontSizeLineage {
        let policy = TerminalFontSizePolicy()
        let configuredRuntimePoints = policy.clampedRuntimePoints(
            configuredRuntimePoints
        )

        let startingRuntimePoints: Float32
        let transform: TerminalFontSizeDeltaTransform
        switch self {
        case .relative(let relativeTransform):
            startingRuntimePoints = sourceLineage.map {
                CmuxSurfaceConfigTemplate.runtimeFontSize(
                    fromBasePoints: $0.basePoints,
                    percent: magnificationPercent
                )
            } ?? configuredRuntimePoints
            transform = relativeTransform
        case .resetThen(let resetTransform):
            startingRuntimePoints = configuredRuntimePoints
            transform = resetTransform
        }

        let boundedStartingRuntimePoints = policy.clampedRuntimePoints(
            startingRuntimePoints
        )
        let finalRuntimePoints = transform.applying(
            to: boundedStartingRuntimePoints
        )
        let isExplicitOverride: Bool
        switch self {
        case .relative:
            isExplicitOverride = true
        case .resetThen(let resetTransform):
            isExplicitOverride = !resetTransform.isIdentity
        }
        return TerminalFontSizeLineage(
            basePoints: CmuxSurfaceConfigTemplate.baseFontSize(
                fromRuntimePoints: finalRuntimePoints,
                percent: magnificationPercent
            ),
            isExplicitOverride: isExplicitOverride
        )
    }
}

@MainActor
@discardableResult
func cmuxApplyTerminalFontSizeChange(
    _ change: WorkspaceTerminalFontSizeChange,
    to terminalPanel: TerminalPanel,
    configuredRuntimePoints: Float32,
    magnificationPercent: Int =
        GlobalFontMagnification.storedPercent
) -> TerminalFontSizeMutationOutcome {
    switch change {
    case .relative(let transform):
        return terminalPanel.surface.adjustFontSizeOutcome(
            applying: transform,
            fallbackRuntimePoints: configuredRuntimePoints,
            magnificationPercent: magnificationPercent
        )
    case .resetThen(let transform):
        let resetOutcome = terminalPanel.surface.resetFontSizeOutcome(
            toConfiguredRuntimePoints: configuredRuntimePoints,
            magnificationPercent: magnificationPercent
        )
        guard resetOutcome.didSucceed else { return .failed }
        guard !transform.isIdentity else { return resetOutcome }
        let adjustmentOutcome =
            terminalPanel.surface.adjustFontSizeOutcome(
                applying: transform,
                fallbackRuntimePoints: configuredRuntimePoints,
                magnificationPercent: magnificationPercent
            )
        guard adjustmentOutcome.didSucceed else { return .failed }
        return resetOutcome.didChange || adjustmentOutcome.didChange
            ? .applied
            : .alreadySatisfied
    }
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
        let configuration =
            GhosttyApp.shared.terminalFontConfigurationSnapshot()
        let configuredRuntimePoints =
            configuration.configuredRuntimePoints
        var changedCount = 0
        var participatingLineage = TerminalFontSizeLineageSelection()
        for terminalPanel in terminalPanels {
            if applyTerminalFontSizeChange(
                change,
                to: terminalPanel,
                configuredRuntimePoints: configuredRuntimePoints,
                magnificationPercent:
                    configuration.magnificationPercent
            ) {
                changedCount += 1
            }
            participatingLineage.consider(
                terminalPanel,
                magnificationPercent:
                    configuration.magnificationPercent
            )
        }

        completeTerminalFontSizeChange(
            change,
            participatingLineage: participatingLineage.lineage,
            configuredRuntimePoints: configuredRuntimePoints,
            magnificationPercent:
                configuration.magnificationPercent
        )
        return changedCount
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
    }

    func configuredTerminalRuntimeFontSize() -> Float32 {
        GhosttyApp.shared.terminalFontConfigurationSnapshot()
            .configuredRuntimePoints
    }

    func beginTerminalFontSizeChangeInheritance(
        token: UUID,
        change: WorkspaceTerminalFontSizeChange,
        configuredRuntimePoints: Float32,
        magnificationPercent: Int =
            GlobalFontMagnification.storedPercent,
        fallbackLineage: TerminalFontSizeLineage? = nil,
        fallbackLineageAlreadyIncludesChange: Bool = false
    ) -> TerminalFontSizeChangeInheritanceContext {
        let preferredSourcePanel =
            lastRememberedTerminalPanelForConfigInheritance()
        let context = TerminalFontSizeChangeInheritanceContext(
            token: token,
            change: change,
            configuredRuntimePoints: configuredRuntimePoints,
            magnificationPercent: magnificationPercent,
            preferredSourcePanel: preferredSourcePanel,
            fallbackLineage:
                fallbackLineage
                ?? lastRememberedTerminalFontSizeLineageForConfigInheritance(),
            fallbackLineageAlreadyIncludesChange:
                fallbackLineageAlreadyIncludesChange
        )
        activeTerminalFontSizeChangeInheritanceContext = context
        rememberTerminalFontSizeLineageForConfigInheritance(
            context.fallbackLineage
        )
        _dockSplit?.beginTerminalFontSizeChangeInheritance(
            token: token,
            change: change,
            configuredRuntimePoints: configuredRuntimePoints,
            magnificationPercent: magnificationPercent,
            fallbackLineage: context.fallbackLineage,
            fallbackLineageAlreadyIncludesChange: true
        )
        return context
    }

    func endTerminalFontSizeChangeInheritance(token: UUID) {
        guard activeTerminalFontSizeChangeInheritanceContext?.token == token else {
            return
        }
        activeTerminalFontSizeChangeInheritanceContext = nil
        _dockSplit?.endTerminalFontSizeChangeInheritance(token: token)
    }

    @discardableResult
    func applyTerminalFontSizeChange(
        _ change: WorkspaceTerminalFontSizeChange,
        to terminalPanel: TerminalPanel,
        configuredRuntimePoints: Float32,
        magnificationPercent: Int =
            GlobalFontMagnification.storedPercent
    ) -> Bool {
        cmuxApplyTerminalFontSizeChange(
            change,
            to: terminalPanel,
            configuredRuntimePoints: configuredRuntimePoints,
            magnificationPercent: magnificationPercent
        ).didChange
    }

    func completeTerminalFontSizeChange(
        _ change: WorkspaceTerminalFontSizeChange,
        participatingLineage: TerminalFontSizeLineage?,
        configuredRuntimePoints: Float32,
        magnificationPercent: Int =
            GlobalFontMagnification.storedPercent
    ) {
        refreshTerminalFontSizeInheritanceSource(
            participatingLineage: participatingLineage,
            magnificationPercent: magnificationPercent
        )
        if case .resetThen(let transform) = change {
            let resetLineage = configuredTerminalFontSizeLineage(
                configuredRuntimePoints: configuredRuntimePoints,
                magnificationPercent: magnificationPercent,
                applying: transform
            )
            if resetLineage.isExplicitOverride {
                rememberTerminalFontSizeLineageForConfigInheritance(
                    resetLineage
                )
            } else if lastRememberedTerminalPanelForConfigInheritance() == nil {
                clearTerminalFontSizeLineageForConfigInheritance()
            }
        } else if lastRememberedTerminalPanelForConfigInheritance() == nil,
                  lastRememberedTerminalFontSizeLineageForConfigInheritance()?
                    .isExplicitOverride == false {
            clearTerminalFontSizeLineageForConfigInheritance()
        }
        _dockSplit?.rememberTerminalFontSizeLineageForNewTerminals(
            fallback:
                lastRememberedTerminalFontSizeLineageForConfigInheritance(),
            magnificationPercent: magnificationPercent
        )
    }

    private func configuredTerminalFontSizeLineage(
        configuredRuntimePoints: Float32,
        magnificationPercent: Int,
        applying transform: TerminalFontSizeDeltaTransform =
            TerminalFontSizeDeltaTransform()
    ) -> TerminalFontSizeLineage {
        let policy = TerminalFontSizePolicy()
        let configuredRuntimePoints = policy.clampedRuntimePoints(
            configuredRuntimePoints
        )
        let finalRuntimePoints = transform.applying(
            to: configuredRuntimePoints
        )
        return TerminalFontSizeLineage(
            basePoints: CmuxSurfaceConfigTemplate.baseFontSize(
                fromRuntimePoints: finalRuntimePoints,
                percent: magnificationPercent
            ),
            isExplicitOverride: finalRuntimePoints != configuredRuntimePoints
        )
    }

    private func refreshTerminalFontSizeInheritanceSource(
        participatingLineage: TerminalFontSizeLineage?,
        magnificationPercent: Int
    ) {
        if let mainTerminalPanel =
            lastRememberedTerminalPanelForConfigInheritance()
                ?? terminalPanelForConfigInheritance() {
            rememberTerminalConfigInheritanceSource(
                mainTerminalPanel,
                magnificationPercent: magnificationPercent
            )
            return
        }
        if let participatingLineage {
            rememberTerminalFontSizeLineageForConfigInheritance(
                participatingLineage
            )
        }
    }
}
