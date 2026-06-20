public import Combine
public import Foundation
public import Observation
public import Bonsplit

/// The per-workspace surface-registry sub-model: owns the per-surface
/// registry annotations and the transient tab-selection/focus-reassert
/// requests the legacy `Workspace` god object kept as loose stored
/// properties (`surfaceTTYNames`, `panelShellActivityStates`,
/// `pendingTabSelection`, `isApplyingTabSelection`,
/// `pendingNonFocusSplitFocusReassert`,
/// `nonFocusSplitFocusReassertGeneration`), plus the per-surface
/// directory/title/listening-port maps (`panelDirectories`, `panelTitles`,
/// `panelCustomTitles`, `surfaceListeningPorts`).
///
/// The surface-id-to-panel-id mapping itself lives in the pane-tree
/// sub-model (`CmuxPanes.PaneTreeModel`), which owns the Bonsplit edge; this
/// model owns the registry state keyed by the workspace-side panel/surface
/// UUIDs and is Bonsplit-free.
///
/// `TabSelectionRequest` is the window's pending tab-selection request type
/// (the app target's `Workspace.PendingTabSelectionRequest`, which carries
/// AppKit hosted-view references and therefore stays app-side).
///
/// Observer parity: `surfaceTTYNames`, `panelShellActivityStates`, and the
/// transient tab-selection/focus-reassert properties were NOT `@Published` on
/// the legacy god object, so they carry no observer-parity hooks. The
/// directory/title maps `panelDirectories`, `panelTitles`, and
/// `panelCustomTitles` WERE `@Published` and fed Combine subscribers
/// (`WorkspaceSidebarObservation`'s sidebar projection consumes
/// `$panelDirectories`; `MobileWorkspaceListObserver` consumes
/// `$panelTitles`/`$panelCustomTitles`/`$panelDirectories`). To preserve that
/// exactly, each mirrors its value into a `CurrentValueSubject` in `didSet`
/// and exposes a matching `…Publisher` accessor replacing the former
/// `$property`: replay-on-subscribe + send-on-every-assignment matches the
/// `@Published` contract those `.map { _ in () }` subscribers relied on.
/// `surfaceListeningPorts` was `@Published` but had no `$` subscriber, so it
/// is a plain storage move with no publisher.
///
/// It also owns the pinned-panel set (`pinnedPanelIds`), the custom-title
/// provenance map (`panelCustomTitleSources`), and the panel title / pin / kind
/// transition logic the legacy `Workspace` god object kept inline
/// (`resolvedPanelTitle`, `panelTitle`, `setPanelCustomTitle`, `panelKind`,
/// `isPanelPinned`, `setPanelPinned`, `syncPinnedStateForTab`,
/// `normalizePinnedTabs`, `insertionIndexToRight`). The live work those
/// transitions need (the panel set, per-panel display title / kind, the
/// surface-id ↔ panel-id mapping, the owning pane, the bonsplit tab reads and
/// writes, and the remote-tmux mirror rename) is irreducibly app-coupled, so it
/// is reached through ``SurfaceRegistryHosting``, conformed by `Workspace` and
/// injected via ``attach(host:)``.
@MainActor
@Observable
public final class SurfaceRegistryModel<TabSelectionRequest> {
    /// The coalesced pending tab-selection request; the workspace drains this
    /// in its re-entrancy-guarded apply loop (legacy
    /// `Workspace.pendingTabSelection`).
    public var pendingTabSelection: TabSelectionRequest?

    /// Re-entrancy guard for the tab-selection apply loop (legacy
    /// `Workspace.isApplyingTabSelection`).
    public var isApplyingTabSelection = false

    /// The pending non-focusing-split focus re-assert request, if any (legacy
    /// `Workspace.pendingNonFocusSplitFocusReassert`).
    public var pendingNonFocusSplitFocusReassert: PendingNonFocusSplitFocusReassert?

    /// Monotonic generation counter for focus re-assert requests; the
    /// workspace wraps with `&+= 1` on each new request (legacy
    /// `Workspace.nonFocusSplitFocusReassertGeneration`).
    public var nonFocusSplitFocusReassertGeneration: UInt64 = 0

    /// The controlling-terminal device name reported for each surface, keyed
    /// by panel id (legacy `Workspace.surfaceTTYNames`).
    public var surfaceTTYNames: [UUID: String] = [:]

    /// The shell-activity classification reported for each terminal panel,
    /// keyed by panel id (legacy `Workspace.panelShellActivityStates`).
    public var panelShellActivityStates: [UUID: PanelShellActivityState] = [:]

    /// The working directory reported for each panel, keyed by panel id
    /// (legacy `Workspace.panelDirectories`).
    public var panelDirectories: [UUID: String] = [:] {
        didSet { panelDirectoriesSubject.send(panelDirectories) }
    }

    /// The latest auto-derived (non-custom) title for each panel, keyed by
    /// panel id (legacy `Workspace.panelTitles`).
    public var panelTitles: [UUID: String] = [:] {
        didSet { panelTitlesSubject.send(panelTitles) }
    }

    /// The user/system custom title override for each panel, keyed by panel
    /// id (legacy `Workspace.panelCustomTitles`).
    public var panelCustomTitles: [UUID: String] = [:] {
        didSet { panelCustomTitlesSubject.send(panelCustomTitles) }
    }

    /// The discovered listening ports for each surface, keyed by panel id
    /// (legacy `Workspace.surfaceListeningPorts`). This map was `@Published`
    /// but had no Combine `$` subscriber, so it has no mirroring subject.
    public var surfaceListeningPorts: [UUID: [Int]] = [:]

    /// The panels the user has pinned, keyed by panel id (legacy
    /// `Workspace.pinnedPanelIds`).
    ///
    /// The legacy property was `@Published` on the `ObservableObject`
    /// `Workspace`, and a SwiftUI reader (`ContentView` reading
    /// `workspace.pinnedPanelIds.contains(panelId)`) re-rendered when it
    /// changed. It carried no Combine `$pinnedPanelIds` subscriber. To preserve
    /// the SwiftUI re-render moment, this property calls ``willChange`` (set by
    /// `Workspace` to `objectWillChange.send()`) at `willSet` time, reproducing
    /// the `@Published` emission moment.
    public var pinnedPanelIds: Set<UUID> = [] {
        willSet { willChange?() }
    }

    /// Provenance of entries in ``panelCustomTitles`` (legacy
    /// `Workspace.panelCustomTitleSources`).
    ///
    /// The legacy property was a plain stored `var` (not `@Published`), so it
    /// never fired `objectWillChange`; this property deliberately omits the
    /// ``willChange`` bridge to preserve that.
    public var panelCustomTitleSources: [UUID: CustomTitleSource] = [:]

    /// Re-entrancy guard for ``normalizePinnedTabs(in:)`` (legacy
    /// `Workspace.isNormalizingPinnedTabOrder`).
    @ObservationIgnored
    private var isNormalizingPinnedTabOrder = false

    /// Forwards the owner's `objectWillChange.send()` so SwiftUI views observing
    /// the owning `ObservableObject` re-render on the same `willSet` moment the
    /// former `@Published` ``pinnedPanelIds`` fired. `nil` until ``attach(host:)``.
    @ObservationIgnored
    public var willChange: (() -> Void)?

    @ObservationIgnored
    private weak var host: (any SurfaceRegistryHosting)?

    @ObservationIgnored
    private lazy var panelDirectoriesSubject = CurrentValueSubject<[UUID: String], Never>(panelDirectories)
    @ObservationIgnored
    private lazy var panelTitlesSubject = CurrentValueSubject<[UUID: String], Never>(panelTitles)
    @ObservationIgnored
    private lazy var panelCustomTitlesSubject = CurrentValueSubject<[UUID: String], Never>(panelCustomTitles)

    /// Emits the current panel directories on subscription, then on every
    /// change (replaces the legacy `Workspace.$panelDirectories`).
    public var panelDirectoriesPublisher: AnyPublisher<[UUID: String], Never> {
        panelDirectoriesSubject.eraseToAnyPublisher()
    }

    /// Emits the current panel titles on subscription, then on every change
    /// (replaces the legacy `Workspace.$panelTitles`).
    public var panelTitlesPublisher: AnyPublisher<[UUID: String], Never> {
        panelTitlesSubject.eraseToAnyPublisher()
    }

    /// Emits the current panel custom titles on subscription, then on every
    /// change (replaces the legacy `Workspace.$panelCustomTitles`).
    public var panelCustomTitlesPublisher: AnyPublisher<[UUID: String], Never> {
        panelCustomTitlesSubject.eraseToAnyPublisher()
    }

    /// Creates an empty registry; the owning workspace populates it as
    /// surfaces register.
    public init() {}

    /// Injects the live-workspace seam. Set before the model's title/pin/kind
    /// methods run so they reach the live panel set and the bonsplit tab state.
    public func attach(host: any SurfaceRegistryHosting) {
        self.host = host
    }

    // MARK: - Titles

    /// Resolves a panel's displayed title: a non-empty custom title wins,
    /// otherwise the trimmed `fallback`, otherwise `"Tab"`. Faithful lift of the
    /// private `Workspace.resolvedPanelTitle(panelId:fallback:)`.
    public func resolvedPanelTitle(panelId: UUID, fallback: String) -> String {
        let trimmedFallback = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackTitle = trimmedFallback.isEmpty ? "Tab" : trimmedFallback
        if let custom = panelCustomTitles[panelId]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !custom.isEmpty {
            return custom
        }
        return fallbackTitle
    }

    /// The resolved displayed title for a panel, or `nil` when the panel is
    /// absent. Faithful lift of `Workspace.panelTitle(panelId:)`.
    public func panelTitle(panelId: UUID) -> String? {
        guard let host, let displayTitle = host.surfaceRegistryPanelDisplayTitle(panelId: panelId) else {
            return nil
        }
        let fallback = panelTitles[panelId] ?? displayTitle
        return resolvedPanelTitle(panelId: panelId, fallback: fallback)
    }

    /// Sets, replaces, or clears (empty/nil `title`) a panel custom title.
    ///
    /// `.auto` writes are rejected when a user-set title exists, and `.auto`
    /// never clears. Returns whether the write landed. Faithful lift of
    /// `Workspace.setPanelCustomTitle(panelId:title:source:)`.
    @discardableResult
    public func setPanelCustomTitle(panelId: UUID, title: String?, source: CustomTitleSource = .user) -> Bool {
        guard let host, host.surfaceRegistryPanelExists(panelId) else { return false }
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let previous = panelCustomTitles[panelId]
        if source == .auto {
            guard !trimmed.isEmpty else { return false }
            if previous != nil, (panelCustomTitleSources[panelId] ?? .user) == .user { return false }
        }
        if trimmed.isEmpty {
            guard previous != nil else { return false }
            panelCustomTitles.removeValue(forKey: panelId)
            panelCustomTitleSources.removeValue(forKey: panelId)
        } else {
            guard previous != trimmed else {
                // Same text: a user write still claims ownership so a later
                // auto write cannot replace a title the user re-confirmed.
                if source == .user { panelCustomTitleSources[panelId] = .user }
                return true
            }
            panelCustomTitles[panelId] = trimmed
            panelCustomTitleSources[panelId] = source
        }

        guard let displayTitle = host.surfaceRegistryPanelDisplayTitle(panelId: panelId),
              let tabId = host.surfaceRegistrySurfaceId(forPanelId: panelId) else { return true }
        let baseTitle = panelTitles[panelId] ?? displayTitle
        host.surfaceRegistryUpdateTab(
            tabId,
            title: resolvedPanelTitle(panelId: panelId, fallback: baseTitle),
            hasCustomTitle: panelCustomTitles[panelId] != nil
        )
        // A remote tmux mirror tab rename propagates to `rename-window`.
        if host.surfaceRegistryIsRemoteTmuxMirror {
            host.surfaceRegistryHandleMirrorWindowRenamed(panelId: panelId, title: trimmed)
        }
        return true
    }

    // MARK: - Kind

    /// The panel's surface-kind wire string, or `nil` when the panel is absent.
    /// Faithful lift of `Workspace.panelKind(panelId:)` (the legacy body resolved
    /// `surfaceKind(for: panel)`, now projected through the host).
    public func panelKind(panelId: UUID) -> String? {
        host?.surfaceRegistryPanelKind(panelId: panelId)
    }

    // MARK: - Pinning

    /// Whether the panel is pinned. Faithful lift of
    /// `Workspace.isPanelPinned(_:)`.
    public func isPanelPinned(_ panelId: UUID) -> Bool {
        pinnedPanelIds.contains(panelId)
    }

    /// Pins or unpins a panel, updating its bonsplit tab and re-normalizing the
    /// pane's tab order. Faithful lift of
    /// `Workspace.setPanelPinned(panelId:pinned:)`.
    public func setPanelPinned(panelId: UUID, pinned: Bool) {
        guard let host, host.surfaceRegistryPanelExists(panelId) else { return }
        let wasPinned = pinnedPanelIds.contains(panelId)
        guard wasPinned != pinned else { return }
        if pinned {
            pinnedPanelIds.insert(panelId)
        } else {
            pinnedPanelIds.remove(panelId)
        }

        guard let tabId = host.surfaceRegistrySurfaceId(forPanelId: panelId),
              let paneId = host.surfaceRegistryPaneId(forPanelId: panelId) else { return }
        host.surfaceRegistryUpdateTab(tabId, isPinned: pinned)
        normalizePinnedTabs(in: paneId)
    }

    /// Re-syncs a tab's bonsplit `isPinned`/`kind` to the registry's pinned set
    /// and the panel's kind, skipping a redundant write. Faithful lift of the
    /// private `Workspace.syncPinnedStateForTab(_:panelId:)`.
    public func syncPinnedStateForTab(_ tabId: TabID, panelId: UUID) {
        guard let host else { return }
        let isPinned = pinnedPanelIds.contains(panelId)
        let kind = host.surfaceRegistryPanelExists(panelId)
            ? host.surfaceRegistryPanelKind(panelId: panelId)
            : nil
        if let tab = host.surfaceRegistryTab(tabId),
           tab.isPinned == isPinned,
           kind.map({ tab.kind == $0 }) ?? true {
            return
        }
        if let kind {
            host.surfaceRegistryUpdateTab(tabId, kind: kind, isPinned: isPinned)
        } else {
            host.surfaceRegistryUpdateTab(tabId, isPinned: isPinned)
        }
    }

    /// Reorders a pane's tabs so pinned tabs lead, idempotently and guarded
    /// against re-entry. Faithful lift of the private
    /// `Workspace.normalizePinnedTabs(in:)`.
    public func normalizePinnedTabs(in paneId: PaneID) {
        guard let host else { return }
        guard !isNormalizingPinnedTabOrder else { return }
        isNormalizingPinnedTabOrder = true
        defer { isNormalizingPinnedTabOrder = false }

        let tabs = host.surfaceRegistryTabs(inPane: paneId)
        let pinnedTabs = tabs.filter { tab in
            guard let panelId = host.surfaceRegistryPanelId(forSurfaceId: tab.id) else { return false }
            return pinnedPanelIds.contains(panelId)
        }
        let unpinnedTabs = tabs.filter { tab in
            guard let panelId = host.surfaceRegistryPanelId(forSurfaceId: tab.id) else { return true }
            return !pinnedPanelIds.contains(panelId)
        }
        let desiredOrder = pinnedTabs + unpinnedTabs

        for (index, desiredTab) in desiredOrder.enumerated() {
            let currentTabs = host.surfaceRegistryTabs(inPane: paneId)
            guard let currentIndex = currentTabs.firstIndex(where: { $0.id == desiredTab.id }) else { continue }
            if currentIndex != index {
                _ = host.surfaceRegistryReorderTab(desiredTab.id, toIndex: index)
            }
        }
    }

    /// The insertion index immediately right of `anchorTabId` within its pane,
    /// never landing before the pinned prefix. Faithful lift of the private
    /// `Workspace.insertionIndexToRight(of:inPane:)`.
    public func insertionIndexToRight(of anchorTabId: TabID, inPane paneId: PaneID) -> Int {
        guard let host else { return 0 }
        let tabs = host.surfaceRegistryTabs(inPane: paneId)
        guard let anchorIndex = tabs.firstIndex(where: { $0.id == anchorTabId }) else { return tabs.count }
        let pinnedCount = tabs.reduce(into: 0) { count, tab in
            if let panelId = host.surfaceRegistryPanelId(forSurfaceId: tab.id), pinnedPanelIds.contains(panelId) {
                count += 1
            }
        }
        let rawTarget = min(anchorIndex + 1, tabs.count)
        return max(rawTarget, pinnedCount)
    }
}
