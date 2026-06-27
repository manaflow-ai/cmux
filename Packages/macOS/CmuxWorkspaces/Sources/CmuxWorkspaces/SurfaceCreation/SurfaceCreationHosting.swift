public import Foundation
public import Bonsplit

/// The live-state seam ``SurfaceCreationCoordinator`` calls back through when it
/// orchestrates the terminal-config-inheritance walk for a freshly created
/// surface.
///
/// The inheritance walk is pure ordering and arithmetic over panel identities
/// (`UUID`), font points (`Float`), and the Sendable `CmuxSurfaceConfigTemplate`,
/// so it belongs in the package. The reads and writes it drives, however, are
/// app-target live state that cannot move until the workspace god model and its
/// `TerminalPanel` are themselves packaged (the Wave-4 decomposition): the
/// ordered candidate panels (which require reads of the bonsplit layout, the
/// workspace panel registry, and the focused/remembered panels), the per-panel
/// Ghostty surface probe (the C bridges `ghostty_surface_inherited_config` and
/// the runtime font-size probe, taken under one ARC pin), and the per-panel
/// lineage/font bookkeeping the workspace persists. The host owns all of that;
/// the coordinator owns only the decision of which candidate to use and how to
/// combine the font points.
///
/// The seam is intentionally coarse: one method gathers every live read for a
/// candidate (so the panel/surface are pinned exactly once, as the legacy body
/// did), and one method applies every write for the chosen candidate (in the
/// legacy order: seed lineage, remember the source, record the last-known font).
/// A conformer reproduces the legacy private `Workspace` helpers exactly:
/// `terminalPanelConfigInheritanceCandidates(preferredPanelId:inPane:)` (the
/// ordered candidate panel IDs), `inheritedTerminalConfig`'s per-candidate read
/// block, and the `terminalInheritanceFontPointsByPanelId` /
/// `lastTerminalConfigInheritanceFontPoints` /
/// `rememberTerminalConfigInheritanceSource` writes.
@MainActor
public protocol SurfaceCreationHosting: AnyObject {
    /// The candidate terminal panel IDs used as the inheritance source, already
    /// ordered by the workspace's priority rule (preferred panel, the preferred
    /// pane's selected terminal, the focused terminal, the last remembered
    /// source, the preferred pane's terminal tabs in order, then every terminal
    /// panel sorted by `id.uuidString`) and de-duplicated. Mirrors the legacy
    /// `Workspace.terminalPanelConfigInheritanceCandidates(preferredPanelId:inPane:)`
    /// mapped to `\.id`.
    func configInheritanceCandidatePanelIds(
        preferredPanelId: UUID?,
        inPane preferredPaneId: PaneID?
    ) -> [UUID]

    /// Gathers the three live reads for `panelId` under a single ARC pin of the
    /// panel and its Ghostty surface, or `nil` when the panel no longer exposes
    /// a live surface (the legacy walk skipped such a candidate via
    /// `guard let sourceSurface`). One call performs the
    /// `cmuxInheritedSurfaceConfig(sourceSurface:context:)` C bridge, the
    /// `terminalInheritanceFontPointsByPanelId[panelId]` lineage-root read, and
    /// the `cmuxCurrentSurfaceFontSizePoints` runtime probe, exactly as the
    /// legacy per-candidate block did inside one
    /// `withExtendedLifetime((terminalPanel, surface))`.
    func probeInheritanceCandidate(panelId: UUID) -> SurfaceInheritanceCandidateProbe?

    /// Applies the writes for the chosen live candidate, mirroring the legacy
    /// body's order and conditions exactly. When `rootedFontPoints` is non-`nil`
    /// (the coordinator resolved a positive lineage value) it seeds
    /// `terminalInheritanceFontPointsByPanelId[panelId]`; it then always calls
    /// `rememberTerminalConfigInheritanceSource(_:)`; and it records
    /// `finalConfigFontPoints` as `lastTerminalConfigInheritanceFontPoints` only
    /// when that value is positive.
    func commitInheritanceSelection(
        panelId: UUID,
        rootedFontPoints: Float?,
        finalConfigFontPoints: Float
    )

    /// The last-known inheritance font points used to synthesize a fallback
    /// config when no live candidate is found, mirroring the read of
    /// `lastTerminalConfigInheritanceFontPoints` in the legacy fallback branch.
    var lastKnownInheritanceFontPoints: Float? { get }

    /// Emits the DEBUG-only `zoom.inherit fallback=lastKnownFont …` log line the
    /// legacy fallback branch logged. A no-op in release builds.
    func logInheritanceFallback(fontPoints: Float)

    // MARK: Create-tab live state

    /// The bonsplit pane that currently holds focus, used to decide whether a new
    /// surface auto-focuses when the caller passes no explicit `focus`, mirroring
    /// the legacy `focus ?? (bonsplitController.focusedPaneId == paneId)` read.
    /// Shared witness with `SplitMoveReorderHosting.focusedBonsplitPaneId`.
    var focusedBonsplitPaneId: PaneID? { get }

    /// The currently focused pane's panel id, captured before the new surface is
    /// registered so the non-focus-split branch can restore it. Mirrors the
    /// legacy `let previousFocusedPanelId = focusedPanelId` read.
    var focusedPanelId: UUID? { get }

    /// The focused terminal panel's hosted Ghostty scroll view as an opaque
    /// reference, captured before registration and handed back to
    /// ``preserveSurfaceFocusAfterNonFocusSplit(preferredPanelId:splitPanelId:previousHostedView:)``.
    /// The package never names the app's `GhosttySurfaceScrollView`, so the host
    /// carries it as `AnyObject?` and downcasts in the witness. Mirrors the legacy
    /// `let previousHostedView = focusedTerminalPanel?.hostedView` read.
    var focusedTerminalHostedView: AnyObject? { get }

    /// Constructs the app's `ProjectPanel` for `projectURL`, registers it in the
    /// workspace panel and panel-title registries, and returns its Sendable
    /// descriptor. Mirrors the legacy
    /// `let projectPanel = ProjectPanel(projectURL: url); panels[projectPanel.id]
    /// = projectPanel; panelTitles[projectPanel.id] = projectPanel.displayTitle`
    /// prelude. The registries stay app-side behind this witness.
    func registerProjectPanel(projectURL: URL) -> SurfaceTabDescriptor

    /// Creates the bonsplit tab for an already-registered surface descriptor and,
    /// on success, records the surface→panel mapping. Returns the new tab id, or
    /// `nil` when `bonsplitController.createTab` fails (the caller then rolls the
    /// registration back via ``discardPanelRegistration(id:)``). Mirrors the
    /// legacy `bonsplitController.createTab(title:icon:kind:isDirty:isLoading:
    /// isPinned:inPane:)` call and the subsequent
    /// `surfaceIdToPanelId[newTabId] = projectPanel.id` write.
    func createSurfaceTab(descriptor: SurfaceTabDescriptor, kind: String, inPane paneId: PaneID) -> TabID?

    /// Reorders the new tab to `index` within its pane, mirroring the legacy
    /// `bonsplitController.reorderTab(newTabId, toIndex: targetIndex)`. Shared
    /// witness with `SplitMoveReorderHosting.reorderTab(_:toIndex:)`.
    @discardableResult
    func reorderTab(_ tabId: TabID, toIndex index: Int) -> Bool

    /// Publishes the `cmux.surface.created` lifecycle event for the new surface,
    /// mirroring the legacy `publishCmuxSurfaceCreated(…)` call. Shared witness
    /// with the `Workspace` lifecycle-event method.
    func publishCmuxSurfaceCreated(_ surfaceId: UUID, paneId: PaneID?, kind: String, origin: String, focused: Bool)

    /// Focuses the pane that received the new surface, mirroring the legacy
    /// `bonsplitController.focusPane(paneId)`. Shared witness with
    /// `SplitMoveReorderHosting.focusPane(_:)`.
    func focusPane(_ paneId: PaneID)

    /// Selects the new tab, mirroring the legacy
    /// `bonsplitController.selectTab(newTabId)`. Shared witness with
    /// `SplitMoveReorderHosting.selectTab(_:)`.
    func selectTab(_ tabId: TabID)

    /// Applies the workspace's tab-selection side effects for the focused new tab,
    /// mirroring the legacy `applyTabSelection(tabId:inPane:)`. Shared witness with
    /// `SplitMoveReorderHosting.applyTabSelection(tabId:inPane:)`.
    func applyTabSelection(tabId: TabID, inPane paneId: PaneID)

    /// Preserves focus on the previously focused panel when a new surface is
    /// created without focus intent, mirroring the legacy
    /// `preserveFocusAfterNonFocusSplit(preferredPanelId:splitPanelId:previousHostedView:)`.
    /// `previousHostedView` is the opaque value from ``focusedTerminalHostedView``;
    /// the witness downcasts it to the app's hosted-view type.
    func preserveSurfaceFocusAfterNonFocusSplit(preferredPanelId: UUID?, splitPanelId: UUID, previousHostedView: AnyObject?)

    /// Rolls back a panel registration when tab creation fails, mirroring the
    /// legacy `panels.removeValue(forKey:); panelTitles.removeValue(forKey:)`
    /// failure branch.
    func discardPanelRegistration(id: UUID)

    /// Reloads the registered project panel after the tab is wired up, mirroring
    /// the legacy `projectPanel.reload()`. The host resolves the typed panel by
    /// `id` and reloads it; a no-op if the id no longer maps to a project panel.
    func reloadProjectPanel(id: UUID)
}
