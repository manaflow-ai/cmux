public import Foundation
public import CmuxSettings

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
}
