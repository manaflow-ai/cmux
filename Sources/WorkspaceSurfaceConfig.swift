import Foundation
import CmuxFoundation
import CmuxTerminalCore

// CmuxSurfaceConfigTemplate and the surface runtime probes moved to
// CmuxTerminalCore (SurfaceValues/CmuxSurfaceConfigTemplate.swift and
// Interop/GhosttySurfaceRuntimeProbe.swift). The legacy free-function names
// below are shims forwarding existing app callers to the probe.

typealias CmuxSurfaceConfigTemplate = CmuxTerminalCore.CmuxSurfaceConfigTemplate

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

private struct TerminalFontSizeLineageSelection {
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
        configuredRuntimePoints: Float32
    ) -> TerminalFontSizeChangeInheritanceContext {
        let preferredSourcePanel =
            lastRememberedTerminalPanelForConfigInheritance()
        let context = TerminalFontSizeChangeInheritanceContext(
            token: token,
            change: change,
            configuredRuntimePoints: configuredRuntimePoints,
            preferredSourcePanel: preferredSourcePanel,
            fallbackLineage:
                lastRememberedTerminalFontSizeLineageForConfigInheritance()
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

    func completeTerminalFontSizeChange(
        _ change: WorkspaceTerminalFontSizeChange,
        participatingLineage: TerminalFontSizeLineage?,
        configuredRuntimePoints: Float32
    ) {
        refreshTerminalFontSizeInheritanceSource(
            participatingLineage: participatingLineage
        )
        if case .resetThen(let transform) = change {
            rememberTerminalFontSizeLineageForConfigInheritance(
                configuredTerminalFontSizeLineage(
                    configuredRuntimePoints: configuredRuntimePoints,
                    applying: transform
                )
            )
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

@MainActor
private struct WorkspaceTerminalFontSizePanelDiscovery {
    enum Origin {
        case workspace
        case workspaceDock
        case remoteMirror(mirrorId: UUID, paneId: Int)
        case windowDock
    }

    struct Candidate {
        let panel: TerminalPanel
        let origin: Origin

        @MainActor
        func isMounted(
            in workspace: Workspace,
            windowDock: DockSplitStore?
        ) -> Bool {
            switch origin {
            case .workspace:
                return (workspace.panels[panel.id] as? TerminalPanel) === panel
            case .workspaceDock:
                return (workspace._dockSplit?.panels[panel.id]
                    as? TerminalPanel) === panel
            case .remoteMirror(let mirrorId, let paneId):
                return workspace.remoteTmuxWindowMirror(forPanelId: mirrorId)?
                    .panelsByPaneId[paneId] === panel
            case .windowDock:
                return (windowDock?.panels[panel.id] as? TerminalPanel) === panel
            }
        }
    }

    enum Visit {
        case candidate(Candidate)
        case nonTerminal
    }

    private enum Phase {
        case workspace
        case workspaceDock
        case remoteMirrors
        case windowDock
        case finished
    }

    private var phase: Phase = .workspace
    private var workspacePanels: Dictionary<UUID, any Panel>.Iterator
    private var workspaceDockPanels:
        Dictionary<UUID, any Panel>.Iterator?
    private var remoteMirrors:
        Dictionary<UUID, RemoteTmuxWindowMirror>.Iterator
    private var remoteMirrorPanels:
        Dictionary<Int, TerminalPanel>.Iterator?
    private var remoteMirrorId: UUID?
    private var windowDockPanels:
        Dictionary<UUID, any Panel>.Iterator?

    init(workspace: Workspace, windowDock: DockSplitStore?) {
        workspacePanels = workspace.panels.makeIterator()
        workspaceDockPanels = workspace._dockSplit?.panels.makeIterator()
        remoteMirrors = workspace.remoteTmuxWindowMirrors.makeIterator()
        windowDockPanels = windowDock?.panels.makeIterator()
    }

    mutating func nextVisit() -> Visit? {
        while true {
            switch phase {
            case .workspace:
                if let (_, panel) = workspacePanels.next() {
                    guard let terminalPanel = panel as? TerminalPanel else {
                        return .nonTerminal
                    }
                    return .candidate(
                        Candidate(panel: terminalPanel, origin: .workspace)
                    )
                }
                phase = .workspaceDock

            case .workspaceDock:
                if let (_, panel) = workspaceDockPanels?.next() {
                    guard let terminalPanel = panel as? TerminalPanel else {
                        return .nonTerminal
                    }
                    return .candidate(
                        Candidate(panel: terminalPanel, origin: .workspaceDock)
                    )
                }
                phase = .remoteMirrors

            case .remoteMirrors:
                if let (paneId, panel) = remoteMirrorPanels?.next(),
                   let remoteMirrorId {
                    return .candidate(
                        Candidate(
                            panel: panel,
                            origin: .remoteMirror(
                                mirrorId: remoteMirrorId,
                                paneId: paneId
                            )
                        )
                    )
                }
                remoteMirrorPanels = nil
                remoteMirrorId = nil
                if let (mirrorId, mirror) = remoteMirrors.next() {
                    remoteMirrorId = mirrorId
                    remoteMirrorPanels = mirror.panelsByPaneId.makeIterator()
                    return .nonTerminal
                }
                phase = .windowDock

            case .windowDock:
                if let (_, panel) = windowDockPanels?.next() {
                    guard let terminalPanel = panel as? TerminalPanel else {
                        return .nonTerminal
                    }
                    return .candidate(
                        Candidate(panel: terminalPanel, origin: .windowDock)
                    )
                }
                phase = .finished

            case .finished:
                return nil
            }
        }
    }
}

@MainActor
final class WorkspaceTerminalFontSizeCoordinator {
    private final class WeakWorkspaceReference {
        weak var value: Workspace?

        init(_ value: Workspace) {
            self.value = value
        }
    }

    private struct PendingRequest {
        let workspaceId: UUID
        var change: WorkspaceTerminalFontSizeChange
    }

    private struct ActiveRequest {
        let request: PendingRequest
        let workspaceReference: WeakWorkspaceReference
        let token: UUID
        var discovery: WorkspaceTerminalFontSizePanelDiscovery
        var pendingCandidate:
            WorkspaceTerminalFontSizePanelDiscovery.Candidate?
        var seenPanelIds: Set<UUID> = []
        var participatingLineage = TerminalFontSizeLineageSelection()
        var windowDockLineage = TerminalFontSizeLineageSelection()
        let configuredRuntimePoints: Float32
    }

    private weak var tabManager: TabManager?
    private weak var windowDock: DockSplitStore?
    private var pendingWindowDockLineage: TerminalFontSizeLineage?
    private var pendingWindowDockInheritanceContext:
        TerminalFontSizeChangeInheritanceContext?

    private var pendingRequests: [PendingRequest] = []
    private var pendingRequestHead = 0
    private var activeRequest: ActiveRequest?
    private var drainGeneration: UInt64 = 0
    private var scheduledDrainGeneration: UInt64?

    init(tabManager: TabManager) {
        self.tabManager = tabManager
    }

    func attachWindowDock(_ dock: DockSplitStore) {
        windowDock = dock
        if let inheritanceContext = pendingWindowDockInheritanceContext {
            dock.beginTerminalFontSizeChangeInheritance(
                token: inheritanceContext.token,
                change: inheritanceContext.change,
                configuredRuntimePoints:
                    inheritanceContext.configuredRuntimePoints,
                fallbackLineage: inheritanceContext.fallbackLineage,
                fallbackLineageAlreadyIncludesChange: true
            )
        } else {
            dock.rememberTerminalFontSizeLineageForNewTerminals(
                fallback: pendingWindowDockLineage
            )
        }
        pendingWindowDockLineage = nil
        pendingWindowDockInheritanceContext = nil
    }

    func enqueue(
        _ change: WorkspaceTerminalFontSizeChange,
        workspaceId: UUID,
        deferFlush: Bool
    ) {
        guard !change.isNoOp else { return }
        append(
            PendingRequest(workspaceId: workspaceId, change: change)
        )
        if deferFlush {
            scheduleDrain()
        } else {
            drain()
        }
    }

    func cancelAll() {
        invalidateScheduledDrain()
        if let activeRequest {
            activeRequest.workspaceReference.value?
                .endTerminalFontSizeChangeInheritance(
                    token: activeRequest.token
                )
            windowDock?.endTerminalFontSizeChangeInheritance(
                token: activeRequest.token
            )
        }
        activeRequest = nil
        pendingRequests.removeAll(keepingCapacity: false)
        pendingRequestHead = 0
        pendingWindowDockLineage = nil
        pendingWindowDockInheritanceContext = nil
    }

#if DEBUG
    func debugFlushOneDrain() {
        invalidateScheduledDrain()
        drain()
    }

    func debugDrainAll() {
        invalidateScheduledDrain()
        while activeRequest != nil || hasPendingRequests {
            drain(scheduleContinuation: false)
        }
    }

    var debugPendingRequestCount: Int {
        pendingRequestCount + (activeRequest == nil ? 0 : 1)
    }
#endif

    private var hasPendingRequests: Bool {
        pendingRequestHead < pendingRequests.count
    }

    private var pendingRequestCount: Int {
        pendingRequests.count - pendingRequestHead
    }

    private func resolveWorkspace(_ workspaceId: UUID) -> Workspace? {
        tabManager?.tabs.first { $0.id == workspaceId }
    }

    private func append(_ request: PendingRequest) {
        guard hasPendingRequests,
              let lastIndex = pendingRequests.indices.last,
              pendingRequests[lastIndex].workspaceId == request.workspaceId
        else {
            pendingRequests.append(request)
            return
        }

        switch request.change {
        case .relative(let transform):
            pendingRequests[lastIndex].change.append(transform)
        case .resetThen(let transform):
            pendingRequests[lastIndex].change.appendReset()
            pendingRequests[lastIndex].change.append(transform)
        }
    }

    private func popPendingRequest() -> PendingRequest? {
        guard hasPendingRequests else { return nil }
        let request = pendingRequests[pendingRequestHead]
        pendingRequestHead += 1
        if pendingRequestHead == pendingRequests.count {
            pendingRequests.removeAll(keepingCapacity: true)
            pendingRequestHead = 0
        } else if pendingRequestHead >= 64,
                  pendingRequestHead * 2 >= pendingRequests.count {
            pendingRequests.removeFirst(pendingRequestHead)
            pendingRequestHead = 0
        }
        return request
    }

    private func activate(_ request: PendingRequest) -> Bool {
        guard let workspace = resolveWorkspace(request.workspaceId) else {
            return false
        }

        let configuredRuntimePoints =
            workspace.configuredTerminalRuntimeFontSize()
        let token = UUID()
        let inheritanceContext =
            workspace.beginTerminalFontSizeChangeInheritance(
                token: token,
                change: request.change,
                configuredRuntimePoints: configuredRuntimePoints
            )

        if let windowDock {
            windowDock.beginTerminalFontSizeChangeInheritance(
                token: token,
                change: request.change,
                configuredRuntimePoints: configuredRuntimePoints,
                fallbackLineage: inheritanceContext.fallbackLineage,
                fallbackLineageAlreadyIncludesChange: true
            )
        } else {
            let previousLineage = pendingWindowDockLineage
            let pendingContext = TerminalFontSizeChangeInheritanceContext(
                token: token,
                change: request.change,
                configuredRuntimePoints: configuredRuntimePoints,
                preferredSourcePanel: nil,
                fallbackLineage:
                    previousLineage ?? inheritanceContext.fallbackLineage,
                fallbackLineageAlreadyIncludesChange:
                    previousLineage == nil
            )
            pendingWindowDockLineage = pendingContext.fallbackLineage
            pendingWindowDockInheritanceContext = pendingContext
        }

        activeRequest = ActiveRequest(
            request: request,
            workspaceReference: WeakWorkspaceReference(workspace),
            token: token,
            discovery: WorkspaceTerminalFontSizePanelDiscovery(
                workspace: workspace,
                windowDock: windowDock
            ),
            configuredRuntimePoints: configuredRuntimePoints
        )
        return true
    }

    private func apply(
        _ candidate: WorkspaceTerminalFontSizePanelDiscovery.Candidate,
        to activeRequest: inout ActiveRequest,
        workspace: Workspace
    ) {
        let terminalPanel = candidate.panel
        let alreadyIncludesChange =
            terminalPanel.surface.hasAppliedFontSizeChange(
                token: activeRequest.token
            )
        if !alreadyIncludesChange {
            _ = workspace.applyTerminalFontSizeChange(
                activeRequest.request.change,
                to: terminalPanel,
                configuredRuntimePoints:
                    activeRequest.configuredRuntimePoints
            )
            terminalPanel.surface.markFontSizeChangeApplied(
                token: activeRequest.token
            )
        }

        activeRequest.participatingLineage.consider(terminalPanel)
        if case .windowDock = candidate.origin {
            activeRequest.windowDockLineage.consider(terminalPanel)
        }
    }

    private func finish(_ activeRequest: ActiveRequest) {
        guard let workspace = resolveWorkspace(
            activeRequest.request.workspaceId
        ), workspace === activeRequest.workspaceReference.value else {
            activeRequest.workspaceReference.value?
                .endTerminalFontSizeChangeInheritance(
                    token: activeRequest.token
                )
            windowDock?.endTerminalFontSizeChangeInheritance(
                token: activeRequest.token
            )
            clearPendingWindowDockContext(token: activeRequest.token)
            return
        }

        workspace.completeTerminalFontSizeChange(
            activeRequest.request.change,
            participatingLineage: activeRequest.participatingLineage.lineage,
            configuredRuntimePoints: activeRequest.configuredRuntimePoints
        )
        workspace.endTerminalFontSizeChangeInheritance(
            token: activeRequest.token
        )
        windowDock?.endTerminalFontSizeChangeInheritance(
            token: activeRequest.token
        )
        clearPendingWindowDockContext(token: activeRequest.token)

        if let windowDock {
            windowDock.rememberTerminalFontSizeLineageForNewTerminals(
                fallback:
                    activeRequest.windowDockLineage.lineage
                    ?? workspace
                        .lastRememberedTerminalFontSizeLineageForConfigInheritance()
            )
        } else if pendingWindowDockLineage == nil {
            pendingWindowDockLineage =
                workspace
                    .lastRememberedTerminalFontSizeLineageForConfigInheritance()
        }
    }

    private func clearPendingWindowDockContext(token: UUID) {
        guard pendingWindowDockInheritanceContext?.token == token else {
            return
        }
        pendingWindowDockInheritanceContext = nil
    }

    private func scheduleDrain() {
        guard scheduledDrainGeneration == nil,
              activeRequest != nil || hasPendingRequests else {
            return
        }
        drainGeneration &+= 1
        let generation = drainGeneration
        scheduledDrainGeneration = generation

        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            MainActor.assumeIsolated {
                guard let self,
                      self.scheduledDrainGeneration == generation else {
                    return
                }
                self.scheduledDrainGeneration = nil
                self.drain()
            }
        }
    }

    private func invalidateScheduledDrain() {
        drainGeneration &+= 1
        scheduledDrainGeneration = nil
    }

    private func drain(scheduleContinuation: Bool = true) {
        var budget = WorkspaceTerminalFontSizeDrainBudget()
        var activeRequestHasBudgetReservation = false

        drainLoop: while true {
            if activeRequest == nil {
                while hasPendingRequests {
                    guard budget.reserveRequestVisit() else {
                        break drainLoop
                    }
                    guard let request = popPendingRequest() else {
                        break
                    }
                    guard activate(request) else { continue }
                    activeRequestHasBudgetReservation = true
                    break
                }
            }

            guard var current = activeRequest else { break }
            if !activeRequestHasBudgetReservation {
                guard budget.reserveRequestVisit() else {
                    break drainLoop
                }
                activeRequestHasBudgetReservation = true
            }

            guard let workspace = resolveWorkspace(
                current.request.workspaceId
            ), workspace === current.workspaceReference.value else {
                activeRequest = nil
                finish(current)
                activeRequestHasBudgetReservation = false
                continue
            }

            if let pendingCandidate = current.pendingCandidate {
                guard pendingCandidate.isMounted(
                    in: workspace,
                    windowDock: windowDock
                ) else {
                    current.pendingCandidate = nil
                    current.seenPanelIds.remove(pendingCandidate.panel.id)
                    activeRequest = current
                    continue
                }
                let alreadyIncludesChange =
                    pendingCandidate.panel.surface.hasAppliedFontSizeChange(
                        token: current.token
                    )
                let panelHasLiveSurface =
                    pendingCandidate.panel.surface.hasLiveSurface
                    && pendingCandidate.panel.surface.surface != nil
                if panelHasLiveSurface,
                   !alreadyIncludesChange,
                   !budget.reserveLiveActions(
                        current.request.change
                            .nativeActionUpperBoundPerLiveSurface
                   ) {
                    activeRequest = current
                    break drainLoop
                }
                current.pendingCandidate = nil
                apply(
                    pendingCandidate,
                    to: &current,
                    workspace: workspace
                )
                activeRequest = current
                continue
            }

            guard budget.reservePanelVisit() else {
                activeRequest = current
                break drainLoop
            }
            guard let visit = current.discovery.nextVisit() else {
                activeRequest = nil
                finish(current)
                activeRequestHasBudgetReservation = false
                continue
            }

            guard case .candidate(let candidate) = visit,
                  candidate.isMounted(
                    in: workspace,
                    windowDock: windowDock
                  ),
                  current.seenPanelIds.insert(candidate.panel.id).inserted
            else {
                activeRequest = current
                continue
            }

            let alreadyIncludesChange =
                candidate.panel.surface.hasAppliedFontSizeChange(
                    token: current.token
                )
            let panelHasLiveSurface =
                candidate.panel.surface.hasLiveSurface
                && candidate.panel.surface.surface != nil
            if panelHasLiveSurface,
               !alreadyIncludesChange,
               !budget.reserveLiveActions(
                    current.request.change
                        .nativeActionUpperBoundPerLiveSurface
               ) {
                current.pendingCandidate = candidate
                activeRequest = current
                break drainLoop
            }

            apply(candidate, to: &current, workspace: workspace)
            activeRequest = current
        }

        if scheduleContinuation,
           activeRequest != nil || hasPendingRequests {
            scheduleDrain()
        }
    }
}

private extension WorkspaceTerminalFontSizeChange {
    mutating func append(_ transform: TerminalFontSizeDeltaTransform) {
        switch self {
        case .relative(var existing):
            existing.append(contentsOf: transform)
            self = .relative(existing)
        case .resetThen(var existing):
            existing.append(contentsOf: transform)
            self = .resetThen(existing)
        }
    }
}
