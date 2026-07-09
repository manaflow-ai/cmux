public import Foundation
public import CmuxSettings
public import CmuxTerminalCore

/// Computes the pure insertion-planning half of the window's new-workspace
/// creation flows over the window's ``WorkspacesModel``: the pre-creation
/// ``WorkspaceCreationSnapshot`` (value-typed identity/pin/inheritance shape),
/// the live-order re-mapping of that snapshot against the current tabs, and the
/// placement-driven insertion index.
///
/// These three computations are lifted one-for-one from the legacy
/// `TabManager.workspaceCreationSnapshotLite`,
/// `TabManager.orderedLiveWorkspaceCreationTabs`, and
/// `TabManager.newTabInsertIndex(snapshot:placementOverride:)` bodies. They are
/// pure functions of the model snapshot plus the caller-supplied inheritance
/// values (the working directory and inherited terminal font), so they live in
/// the package next to the model and are machine-diffable against the originals.
///
/// **What stays in the window-side `TabManager`.** The creation *orchestration*
/// — booting the `Workspace` object, inheriting window chrome, retaining ARC
/// lifetimes across the creation chain, allocating the port ordinal, publishing
/// the `cmux.workspace.created` lifecycle events, applying selection/focus, and
/// the welcome-command send — is irreducibly app-coupled (it reaches the
/// `Workspace` god object, `AppDelegate`, the notification center, Sentry, and
/// the UI-test recorder), so it remains in the god file and calls these pure
/// computations. No app effect is inverted through this coordinator, so it owns
/// no host seam; the moment creation orchestration is itself lifted, the
/// app-side effects it interleaves invert through a host the way the sibling
/// close/reorder coordinators do.
///
/// **Why synchronous and `@MainActor`.** Every computation reads the
/// main-actor-isolated ``WorkspacesModel`` inside the single creation turn that
/// drives it; co-locating on the main actor removes any bridging (mirrors the
/// sibling workspace coordinators' isolation ruling).
@MainActor
public final class WorkspaceCreationCoordinator<Tab: WorkspaceTabRepresenting> {
    private let model: WorkspacesModel<Tab>
    private let settings: any SettingsReading
    private let catalog: SettingCatalog
    private let debugLog: @Sendable (String) -> Void
    private weak var host: (any WorkspaceCreationHosting<Tab>)?

    /// Creates the coordinator over the window's workspace model, reading new-
    /// workspace placement from the supplied settings + catalog.
    ///
    /// `debugLog` carries the app's DEBUG `cmuxDebugLog` sink so the
    /// re-entrant-snapshot fallback line is emitted exactly as the legacy
    /// `#if DEBUG` body did; the app passes a no-op in release. Keeping the sink
    /// app-side matches the package convention (the sidebar-git service is wired
    /// the same way), so the package never depends on a DEBUG-only log facility.
    public init(
        model: WorkspacesModel<Tab>,
        settings: any SettingsReading,
        catalog: SettingCatalog,
        debugLog: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.model = model
        self.settings = settings
        self.catalog = catalog
        self.debugLog = debugLog
    }

    /// Attaches the window-side creation-effect seam (the `Workspace`/`AppDelegate`
    /// reach the creation orchestration inverts through). Wired before the first
    /// `addWorkspace` so the initial creation's effects reach the host with the
    /// legacy in-class timing.
    public func attach(host: any WorkspaceCreationHosting<Tab>) {
        self.host = host
    }

    /// Builds a ``WorkspaceCreationSnapshot`` from pre-extracted value-type data.
    ///
    /// Lifts the legacy `TabManager.workspaceCreationSnapshotLite` body
    /// one-for-one. The caller obtains `preferredWorkingDirectory` and
    /// `inheritedTerminalFontPoints` through the live workspaces (which it keeps
    /// alive), so this function copies only the tiny value snapshot out of each
    /// workspace. Each copy is taken under `withExtendedLifetime` because the
    /// optimized arm64 Nightly build can otherwise over-release during the map,
    /// crashing in `swift_release` / snapshot creation.
    public func workspaceCreationSnapshotLite(
        currentTabs: [Tab],
        currentSelectedTabId: UUID?,
        preferredWorkingDirectory: String?,
        inheritedTerminalFontPoints: Float?
    ) -> WorkspaceCreationSnapshot {
        var tabSnapshots: [WorkspaceCreationTabSnapshot] = []
        tabSnapshots.reserveCapacity(currentTabs.count)
        for workspace in currentTabs {
            // Keep each Workspace alive while copying the tiny value snapshot out of it.
            // The optimized arm64 Nightly build can otherwise over-release during
            // Collection.map, crashing here in swift_release / snapshot creation.
            let snapshot = withExtendedLifetime(workspace) {
                WorkspaceCreationTabSnapshot(id: workspace.id, isPinned: workspace.isPinned)
            }
            tabSnapshots.append(snapshot)
        }
        let selectedTabSnapshot = currentSelectedTabId.flatMap { selectedTabId in
            tabSnapshots.first(where: { $0.id == selectedTabId })
        }

        return WorkspaceCreationSnapshot(
            tabs: tabSnapshots,
            selectedTabId: currentSelectedTabId,
            selectedTabWasPinned: selectedTabSnapshot?.isPinned ?? false,
            preferredWorkingDirectory: preferredWorkingDirectory,
            inheritedTerminalFontPoints: inheritedTerminalFontPoints
        )
    }

    /// Builds the inherited-surface config template a new workspace boots with
    /// from the inherited terminal font points, or `nil` when there is no
    /// positive font to seed. Lifts the legacy
    /// `TabManager.workspaceCreationConfigTemplate(inheritedTerminalFontPoints:)`
    /// body one-for-one.
    ///
    /// A clean Swift-owned ``CmuxSurfaceConfigTemplate`` is rebuilt here rather
    /// than carrying over any pointer-backed inherited config state from the
    /// source workspace, so the value is pure over the `Float?` input and lives
    /// in the package next to the rest of the creation planning. The host
    /// witness (`makeWorkspaceForCreation`) and the detached-workspace path
    /// forward to it for the single source of truth.
    public func workspaceCreationConfigTemplate(
        inheritedTerminalFontPoints: Float?
    ) -> CmuxSurfaceConfigTemplate? {
        guard let inheritedTerminalFontPoints, inheritedTerminalFontPoints > 0 else {
            return nil
        }
        // Rebuild a clean Swift-owned template instead of carrying over any pointer-backed
        // inherited config state from the source workspace.
        var config = CmuxSurfaceConfigTemplate()
        config.fontSize = inheritedTerminalFontPoints
        return config
    }

    /// The working directory a new tab inherits from a source workspace: the
    /// first non-empty normalized directory from `currentDirectory` followed by
    /// `orderedPanelDirectories`, or `nil` when none normalizes non-empty. Lifts
    /// the legacy `TabManager.preferredWorkingDirectoryForNewTab(workspace:)`
    /// body one-for-one.
    ///
    /// Uses cached directory state only; avoiding live focus traversal keeps
    /// workspace creation resilient when Bonsplit is in the middle of a rapid
    /// Cmd+N churn. `normalize` is the app-side git-probe normalizer
    /// (`String.nonEmptyNormalizedGitProbeDirectory` from CmuxSidebarGit), passed
    /// in so the package never depends on the git subsystem; it returns the
    /// normalized directory or `nil` when blank.
    public func preferredWorkingDirectoryForNewTab(
        currentDirectory: String?,
        orderedPanelDirectories: [String],
        normalize: (String?) -> String?
    ) -> String? {
        if let currentDirectory = normalize(currentDirectory) {
            return currentDirectory
        }
        // Equivalent to the legacy `panelDirectories.values.lazy.compactMap(normalize).first`:
        // return the first panel directory that normalizes non-empty. A manual loop keeps
        // `normalize` non-escaping (a lazy chain would capture it into an escaping closure).
        for directory in orderedPanelDirectories {
            if let normalized = normalize(directory) {
                return normalized
            }
        }
        return nil
    }

    /// The implicit working directory a new workspace inherits from a source
    /// workspace when `inheritWorkingDirectory` is set, or `nil`. Lifts the
    /// legacy `TabManager.implicitWorkingDirectoryForNewWorkspace(from:)` body
    /// one-for-one; the inherit-working-directory setting read stays app-side and
    /// is threaded in as `inheritWorkingDirectory`.
    public func implicitWorkingDirectoryForNewWorkspace(
        inheritWorkingDirectory: Bool,
        currentDirectory: String?,
        orderedPanelDirectories: [String],
        normalize: (String?) -> String?
    ) -> String? {
        guard inheritWorkingDirectory else {
            return nil
        }
        return preferredWorkingDirectoryForNewTab(
            currentDirectory: currentDirectory,
            orderedPanelDirectories: orderedPanelDirectories,
            normalize: normalize
        )
    }

    // MARK: - Creation chrome inheritance (tab-bar leading inset)

    /// The tab-bar leading inset a new workspace inherits during creation: the
    /// window's current inset when set, otherwise the source workspace's current
    /// inset, otherwise `nil`. Lifts the legacy
    /// `TabManager.applyCreationChromeInheritance` resolution one-for-one.
    ///
    /// `sourceTabBarLeadingInset` is a non-escaping closure so the source
    /// workspace's bonsplit appearance is read only when the window inset is
    /// `nil`, preserving the legacy `??` short-circuit. The bonsplit-appearance
    /// read and the `currentWindowTabBarLeadingInset` stored property stay
    /// window-side (the stored property cannot cross the module boundary and the
    /// appearance lives on the app-target `Workspace`); the window threads both
    /// through this pure resolution.
    public func inheritedTabBarLeadingInset(
        currentWindowTabBarLeadingInset: CGFloat?,
        sourceTabBarLeadingInset: () -> CGFloat?
    ) -> CGFloat? {
        currentWindowTabBarLeadingInset ?? sourceTabBarLeadingInset()
    }

    /// Normalizes a tab-bar leading inset to be non-negative. Lifts the legacy
    /// `TabManager.syncWorkspaceTabBarLeadingInset` `max(0, inset)` one-for-one.
    public func normalizedTabBarLeadingInset(_ inset: CGFloat) -> CGFloat {
        max(0, inset)
    }

    /// Whether a workspace's tab-bar leading inset needs rewriting to reach
    /// `new` from its `current` value. Lifts the legacy
    /// `TabManager.applyTabBarLeadingInset` change-gate one-for-one; the actual
    /// bonsplit-appearance write stays window-side.
    public func tabBarLeadingInsetNeedsApply(current: CGFloat, new: CGFloat) -> Bool {
        current != new
    }

    /// Re-maps the snapshot's tab order onto the model's current live order, or
    /// `nil` when the live tabs no longer match the snapshot (a re-entrant
    /// create/close/reorder happened mid-creation). Lifts the legacy
    /// `TabManager.orderedLiveWorkspaceCreationTabs(from:)` body one-for-one.
    public func orderedLiveWorkspaceCreationTabs(
        from snapshot: WorkspaceCreationSnapshot
    ) -> [WorkspaceCreationTabSnapshot]? {
        let currentTabs = model.tabs
        let snapshotTabsById = Dictionary(uniqueKeysWithValues: snapshot.tabs.map { ($0.id, $0) })
        var orderedTabs: [WorkspaceCreationTabSnapshot] = []
        orderedTabs.reserveCapacity(currentTabs.count)

        for workspace in currentTabs {
            guard let tabSnapshot = snapshotTabsById[workspace.id] else {
#if DEBUG
                debugLog(
                    "workspace.create.reentrantSnapshotFallback " +
                    "snapshotCount=\(snapshot.tabs.count) liveCount=\(currentTabs.count)"
                )
#endif
                return nil
            }
            orderedTabs.append(tabSnapshot)
        }

        return orderedTabs
    }

    /// The insertion index for a new workspace, resolving the effective
    /// placement (override / iMessage-mode / stored setting) against the live
    /// order re-mapped from `snapshot`. Lifts the legacy
    /// `TabManager.newTabInsertIndex(snapshot:placementOverride:)` body
    /// one-for-one.
    public func newTabInsertIndex(
        snapshot: WorkspaceCreationSnapshot,
        placementOverride: WorkspacePlacement? = nil
    ) -> Int {
        let placement = WorkspacePlacement.effectivePlacement(
            placementOverride: placementOverride,
            settings: settings,
            catalog: catalog
        )
        let liveTabs = orderedLiveWorkspaceCreationTabs(from: snapshot) ?? snapshot.tabs
        let pinnedCount = liveTabs.reduce(into: 0) { partial, tab in
            if tab.isPinned {
                partial += 1
            }
        }

        switch placement {
        case .top:
            return pinnedCount
        case .end:
            return liveTabs.count
        case .afterCurrent:
            if let selectedTabId = snapshot.selectedTabId,
               let selectedIndex = liveTabs.firstIndex(where: { $0.id == selectedTabId }) {
                return placement.insertionIndex(
                    selectedIndex: selectedIndex,
                    selectedIsPinned: snapshot.selectedTabWasPinned,
                    pinnedCount: pinnedCount,
                    totalCount: liveTabs.count
                )
            }
            return snapshot.selectedTabWasPinned ? pinnedCount : liveTabs.count
        }
    }

    // MARK: - Creation orchestration (legacy TabManager.addWorkspace / addTab)

    /// Creates a new workspace, inserts it into the window's ``WorkspacesModel``,
    /// and runs the full creation sequence. Lifts the legacy
    /// `TabManager.addWorkspace(...)` body one-for-one: the pre-creation
    /// inheritance reads, the `withExtendedLifetime` ARC guard around the whole
    /// chain, the snapshot capture + DEBUG dev-mutation hook, the breadcrumb,
    /// working-directory/font/config resolution, placement-driven insertion
    /// index, port-ordinal allocation, default-title resolution, workspace boot +
    /// chrome inheritance, background-load request, the live-array insertion +
    /// group-contiguity normalization, the initial git-metadata schedule, the
    /// eager-load surface prime, the two lifecycle publishes, the selection +
    /// focus-notification block, the DEBUG UITest telemetry, and the welcome
    /// send — in that exact order.
    ///
    /// Model mutations (`tabs` insertion, `normalizeWorkspaceGroupContiguity`,
    /// `selectedTabId`) run here over the model; every app-coupled effect inverts
    /// through ``WorkspaceCreationHosting``.
    ///
    /// Traps when the host is unattached: the window wires the host before its
    /// first `addWorkspace`, and there is no meaningful workspace to return
    /// without it (the legacy code unconditionally constructed one).
    @discardableResult
    public func addWorkspace(
        title: String? = nil,
        workingDirectory overrideWorkingDirectory: String? = nil,
        initialSurface: NewWorkspaceInitialSurface = .terminal,
        initialTerminalCommand: String? = nil,
        initialTerminalInput: String? = nil,
        initialTerminalEnvironment: [String: String] = [:],
        initialBrowserURL: URL? = nil,
        initialBrowserOmnibarVisible: Bool = true,
        initialBrowserTransparentBackground: Bool = false,
        workspaceEnvironment: [String: String] = [:],
        inheritWorkingDirectory: Bool = true,
        select: Bool = true,
        eagerLoadTerminal: Bool = false,
        placementOverride: WorkspacePlacement? = nil,
        autoWelcomeIfNeeded: Bool = true,
        autoRefreshMetadata: Bool = true,
        normalizeWorkspaceGroupsAfterInsert: Bool = true,
        allowTextBoxFocusDefault: Bool = true
    ) -> Tab {
        guard let host else {
            preconditionFailure(
                "WorkspaceCreationCoordinator.addWorkspace requires an attached WorkspaceCreationHosting host"
            )
        }
        let sourceWorkspace = host.creationSourceWorkspace()
        let capturedTabs = model.tabs
        // Snapshot the selected tab from the pinned workspace instead of rereading the
        // @Published selectedTabId storage after the inheritance helpers. The arm64 Nightly
        // Cmd+N crash is in PublishedSubject.value.getter on that second getter read.
        let capturedSelectedTabId = sourceWorkspace?.id
        // Keep both the source workspace and the pre-creation workspace array alive for the
        // entire creation path. Release ARC can otherwise drop retains early across the
        // helper/insertion chain, which reintroduces use-after-free crashes in optimized builds.
        return withExtendedLifetime((capturedTabs, sourceWorkspace)) {
            let dir = host.implicitWorkingDirectory(
                inheritWorkingDirectory: inheritWorkingDirectory,
                from: sourceWorkspace
            )
            let font = host.inheritedTerminalFontPoints(from: sourceWorkspace)
            let snapshot = workspaceCreationSnapshotLite(
                currentTabs: capturedTabs,
                currentSelectedTabId: capturedSelectedTabId,
                preferredWorkingDirectory: dir,
                inheritedTerminalFontPoints: font
            )
            host.didCaptureWorkspaceCreationSnapshot()
#if DEBUG
            host.maybeMutateSelectionDuringWorkspaceCreationForDev(snapshot: snapshot)
#endif
            let nextTabCount = snapshot.tabs.count + 1
            host.recordWorkspaceCreateBreadcrumb(tabCount: nextTabCount)
            let explicitWorkingDirectory = host.normalizedWorkingDirectory(overrideWorkingDirectory)
            let workingDirectory = explicitWorkingDirectory ?? snapshot.preferredWorkingDirectory
            // Resolve placement against the pre-creation snapshot before Workspace init
            // boots terminal state. The ssh/new-workspace path can otherwise crash while
            // reading @Published placement state from existing workspaces mid-creation.
            let insertIndex = newTabInsertIndex(snapshot: snapshot, placementOverride: placementOverride)
            let ordinal = host.nextPortOrdinal()
            let defaultTitle: String
            switch initialSurface {
            case .terminal:
                defaultTitle = host.terminalDefaultWorkspaceTitle(tabNumber: nextTabCount)
            case .browser:
                // Match the browser surface's blank new-tab title; the
                // single-panel title sync keeps the workspace title following
                // the page title once the user navigates.
                defaultTitle = host.browserDefaultWorkspaceTitle()
            case .cloudVMLoading:
                defaultTitle = host.cloudVMDefaultWorkspaceTitle()
            }
            let newWorkspace = host.makeWorkspaceForCreation(
                title: title ?? defaultTitle,
                explicitTitle: title,
                workingDirectory: workingDirectory,
                portOrdinal: ordinal,
                inheritedTerminalFontPoints: snapshot.inheritedTerminalFontPoints,
                initialSurface: initialSurface,
                initialTerminalCommand: initialTerminalCommand,
                initialTerminalInput: initialTerminalInput,
                initialTerminalEnvironment: initialTerminalEnvironment,
                initialBrowserURL: initialBrowserURL,
                initialBrowserOmnibarVisible: initialBrowserOmnibarVisible,
                initialBrowserTransparentBackground: initialBrowserTransparentBackground,
                workspaceEnvironment: workspaceEnvironment,
                allowTextBoxFocusDefault: allowTextBoxFocusDefault,
                chromeInheritanceSource: sourceWorkspace ?? capturedTabs.first
            )
            if eagerLoadTerminal && !select {
                host.requestBackgroundWorkspaceLoad(workspaceId: newWorkspace.id)
            }
            // Apply insertion to the current live array so post-snapshot closes/reorders
            // are preserved instead of reintroducing stale workspace instances.
            var updatedTabs = model.tabs
            if insertIndex >= 0 && insertIndex <= updatedTabs.count {
                updatedTabs.insert(newWorkspace, at: insertIndex)
            } else {
                updatedTabs.append(newWorkspace)
            }
            model.tabs = updatedTabs
            // The global insertion-index rules don't know about group sections.
            // Re-run the group-aware normalize so a freshly-added workspace
            // can't land inside another group's contiguous section.
            if normalizeWorkspaceGroupsAfterInsert, !model.workspaceGroups.isEmpty {
                model.normalizeWorkspaceGroupContiguity()
            }
            if autoRefreshMetadata {
                host.scheduleInitialWorkspaceGitMetadataRefreshIfPossible(newWorkspace)
            }
            if eagerLoadTerminal {
                if select {
                    host.requestBackgroundSurfaceStartIfNeeded(newWorkspace)
                }
            }
            host.publishWorkspaceCreated(newWorkspace, selected: select)
            host.publishInitialSurfaceCreated(newWorkspace, selected: select)
            if select {
#if DEBUG
                host.debugPrimeWorkspaceSwitchTrigger(to: newWorkspace.id)
#endif
                model.selectedTabId = newWorkspace.id
                host.postDidFocusTab(workspaceId: newWorkspace.id)
            }
#if DEBUG
            host.recordAddTabUITestTelemetry(
                tabCount: updatedTabs.count,
                selectedTabId: select ? newWorkspace.id.uuidString : (snapshot.selectedTabId?.uuidString ?? "")
            )
#endif
            if autoWelcomeIfNeeded && select && initialSurface == .terminal
                && host.shouldSendWelcomeCommand() {
                host.sendWelcomeCommandWhenReady(to: newWorkspace)
            }
            return newWorkspace
        }
    }

    /// Convenience alias for ``addWorkspace(title:workingDirectory:initialSurface:initialTerminalCommand:initialTerminalInput:initialTerminalEnvironment:workspaceEnvironment:inheritWorkingDirectory:select:eagerLoadTerminal:placementOverride:autoWelcomeIfNeeded:autoRefreshMetadata:normalizeWorkspaceGroupsAfterInsert:)``
    /// with the two parameters the legacy `addTab` exposed (legacy
    /// `TabManager.addTab(select:eagerLoadTerminal:)`).
    @discardableResult
    public func addTab(select: Bool = true, eagerLoadTerminal: Bool = false) -> Tab {
        addWorkspace(select: select, eagerLoadTerminal: eagerLoadTerminal)
    }
}
