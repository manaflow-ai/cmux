import Foundation
import CmuxFoundation
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
        let configuredLineage = TerminalFontSizeLineage(
            basePoints: CmuxSurfaceConfigTemplate.baseFontSize(
                fromRuntimePoints: configuredRuntimePoints,
                percent: magnificationPercent
            ),
            isExplicitOverride: false
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
        if case .relative = self,
           finalRuntimePoints == boundedStartingRuntimePoints {
            return sourceLineage ?? configuredLineage
        }
        let isExplicitOverride: Bool
        switch self {
        case .relative:
            isExplicitOverride = true
        case .resetThen:
            isExplicitOverride =
                finalRuntimePoints != configuredRuntimePoints
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
    configuredRuntimePoints: Float32
) -> Bool {
    switch change {
    case .relative(let transform):
        return terminalPanel.surface.adjustFontSize(
            applying: transform,
            fallbackRuntimePoints: configuredRuntimePoints
        )
    case .resetThen(let transform):
        let didReset = terminalPanel.surface.resetFontSize(
            toConfiguredRuntimePoints: configuredRuntimePoints
        )
        guard !transform.isIdentity else { return didReset }
        let didAdjust = terminalPanel.surface.adjustFontSize(
            applying: transform,
            fallbackRuntimePoints: configuredRuntimePoints
        )
        return didReset || didAdjust
    }
}

@MainActor
struct TerminalFontSizeChangeInheritanceContext {
    let token: UUID
    let change: WorkspaceTerminalFontSizeChange
    let configuredRuntimePoints: Float32
    let magnificationPercent: Int
    let fallbackLineage: TerminalFontSizeLineage
    let initialLineageProbeCount: Int

    init(
        token: UUID,
        change: WorkspaceTerminalFontSizeChange,
        configuredRuntimePoints: Float32,
        preferredSourcePanel: TerminalPanel?,
        fallbackLineage: TerminalFontSizeLineage?,
        fallbackLineageAlreadyIncludesChange: Bool = false
    ) {
        self.token = token
        self.change = change
        self.configuredRuntimePoints = configuredRuntimePoints
        let magnificationPercent = GlobalFontMagnification.storedPercent
        self.magnificationPercent = magnificationPercent

        let preferredSourceLineage =
            preferredSourcePanel?.surface.fontSizeLineageSnapshot()
        initialLineageProbeCount = preferredSourcePanel == nil ? 0 : 1
        if preferredSourceLineage == nil,
           fallbackLineageAlreadyIncludesChange,
           let fallbackLineage {
            self.fallbackLineage = fallbackLineage
        } else {
            self.fallbackLineage = change.resultingInheritanceLineage(
                from: preferredSourceLineage ?? fallbackLineage,
                configuredRuntimePoints: configuredRuntimePoints,
                magnificationPercent: magnificationPercent
            )
        }
    }

    func inheritedLineage(
        from sourceTerminalPanel: TerminalPanel?
    ) -> TerminalFontSizeLineage {
        guard let sourceTerminalPanel else { return fallbackLineage }
        let sourceLineage =
            sourceTerminalPanel.surface.fontSizeLineageSnapshot()
        if sourceTerminalPanel.surface.hasAppliedFontSizeChange(token: token) {
            return sourceLineage ?? fallbackLineage
        }
        if let sourceLineage {
            return change.resultingInheritanceLineage(
                from: sourceLineage,
                configuredRuntimePoints: configuredRuntimePoints,
                magnificationPercent: magnificationPercent
            )
        }
        return fallbackLineage
    }
}

struct TerminalFontSizeLineageSelection {
    private var panelIdSortKey: String?
    private(set) var lineage: TerminalFontSizeLineage?

    @MainActor
    mutating func consider(_ terminalPanel: TerminalPanel) {
        guard let candidateLineage =
                terminalPanel.surface.fontSizeLineageSnapshot() else {
            return
        }
        let candidateSortKey = terminalPanel.id.uuidString
        guard panelIdSortKey.map({ candidateSortKey < $0 }) ?? true else {
            return
        }
        panelIdSortKey = candidateSortKey
        lineage = candidateLineage
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
        let configuredRuntimePoints = configuredTerminalRuntimeFontSize()
        var changedCount = 0
        var participatingLineage = TerminalFontSizeLineageSelection()
        for terminalPanel in terminalPanels {
            if applyTerminalFontSizeChange(
                change,
                to: terminalPanel,
                configuredRuntimePoints: configuredRuntimePoints
            ) {
                changedCount += 1
            }
            participatingLineage.consider(terminalPanel)
        }

        completeTerminalFontSizeChange(
            change,
            participatingLineage: participatingLineage.lineage,
            configuredRuntimePoints: configuredRuntimePoints
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
        Float32(
            GhosttyConfig.load(
                globalFontMagnificationPercent: GlobalFontMagnification.storedPercent
            ).fontSize
        )
    }

    func beginTerminalFontSizeChangeInheritance(
        token: UUID,
        change: WorkspaceTerminalFontSizeChange,
        configuredRuntimePoints: Float32,
        fallbackLineage: TerminalFontSizeLineage? = nil,
        fallbackLineageAlreadyIncludesChange: Bool = false
    ) -> TerminalFontSizeChangeInheritanceContext {
        let preferredSourcePanel =
            lastRememberedTerminalPanelForConfigInheritance()
        let context = TerminalFontSizeChangeInheritanceContext(
            token: token,
            change: change,
            configuredRuntimePoints: configuredRuntimePoints,
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
        configuredRuntimePoints: Float32
    ) -> Bool {
        cmuxApplyTerminalFontSizeChange(
            change,
            to: terminalPanel,
            configuredRuntimePoints: configuredRuntimePoints
        )
    }

    func completeTerminalFontSizeChange(
        _ change: WorkspaceTerminalFontSizeChange,
        participatingLineage: TerminalFontSizeLineage?,
        configuredRuntimePoints: Float32
    ) {
        refreshTerminalFontSizeInheritanceSource(
            participatingLineage: participatingLineage
        )
        if case .resetThen(let transform) = change {
            let resetLineage = configuredTerminalFontSizeLineage(
                configuredRuntimePoints: configuredRuntimePoints,
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
            fallback: lastRememberedTerminalFontSizeLineageForConfigInheritance()
        )
    }

    private func configuredTerminalFontSizeLineage(
        configuredRuntimePoints: Float32,
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
                percent: GlobalFontMagnification.storedPercent
            ),
            isExplicitOverride: finalRuntimePoints != configuredRuntimePoints
        )
    }

    private func refreshTerminalFontSizeInheritanceSource(
        participatingLineage: TerminalFontSizeLineage?
    ) {
        if let mainTerminalPanel =
            lastRememberedTerminalPanelForConfigInheritance()
                ?? terminalPanelForConfigInheritance() {
            rememberTerminalConfigInheritanceSource(mainTerminalPanel)
            return
        }
        if let participatingLineage {
            rememberTerminalFontSizeLineageForConfigInheritance(
                participatingLineage
            )
        }
    }
}
