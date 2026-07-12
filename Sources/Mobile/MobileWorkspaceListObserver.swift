import Combine
import CmuxWorkspaces
import Foundation
import OSLog

private let mobileWorkspaceObserverLog = Logger(subsystem: "dev.cmux", category: "mobile-workspace-observer")

/// Immutable, versioned value sampled from the Mac hierarchy on the main actor.
/// Publishers and focus notifications only request a new sample. They are never
/// treated as the state carried by an event, which avoids mixing `willSet`
/// values with later live reads from other hierarchy dimensions.
struct MobileWorkspaceHierarchyProjection {
    static let schemaVersion = 1

    struct PaneListValue: Hashable {
        let id: UUID
        let spatialIndex: Int
        let terminalIDs: [UUID]
    }

    struct PanePayloadValue: Hashable {
        let id: UUID
        let spatialIndex: Int
        let isFocused: Bool
        let terminalIDs: [UUID]
    }

    struct TerminalListValue: Hashable {
        let id: UUID
        let title: String
        let currentDirectory: String?
        let paneID: UUID?
        let canClose: Bool
        let requiresCloseConfirmation: Bool
        let isReady: Bool
    }

    struct TerminalPayloadValue: Hashable {
        let list: TerminalListValue
        let isFocused: Bool
    }

    struct SurfaceListValue: Hashable {
        let id: UUID
        let title: String?
        let reportedDirectory: String?
    }

    struct PanelDirectoryValue: Hashable {
        let id: UUID
        let directory: String?
    }

    struct ListValue: Hashable {
        let schemaVersion: Int
        let id: UUID
        let title: String
        let isPinned: Bool
        let groupID: UUID?
        let previewSignature: Int?
        let orderedPanelIDs: [UUID]
        let pinnedPanelIDs: [UUID]
        let panes: [PaneListValue]
        let terminals: [TerminalListValue]
        let surfaces: [SurfaceListValue]
        let currentDirectory: String?
        let panelDirectories: [PanelDirectoryValue]
    }

    struct PaneFocusValue: Hashable {
        let id: UUID
        let selectedTerminalID: UUID?
    }

    struct FocusValue: Hashable {
        let schemaVersion: Int
        let workspaceID: UUID
        let focusedPaneID: UUID?
        let selectedTerminalID: UUID?
        let paneSelections: [PaneFocusValue]

        var eventPayload: [String: Any] {
            [
                "kind": "focus",
                "workspace_id": workspaceID.uuidString,
                "focused_pane_id": focusedPaneID?.uuidString ?? NSNull(),
                "selected_terminal_id": selectedTerminalID?.uuidString ?? NSNull(),
            ]
        }
    }

    let list: ListValue
    let focus: FocusValue
    let panes: [PanePayloadValue]
    let terminals: [TerminalPayloadValue]

    @MainActor
    init(workspace: Workspace, previewSignature: Int? = nil) {
        let paneIDs = workspace.bonsplitController.allPaneIds
        let focusedPaneID = workspace.bonsplitController.focusedPaneId?.id
        var paneIDByTerminalID: [UUID: UUID] = [:]
        var paneListValues: [PaneListValue] = []
        var panePayloadValues: [PanePayloadValue] = []
        var paneFocusValues: [PaneFocusValue] = []
        for (spatialIndex, paneID) in paneIDs.enumerated() {
            let terminalIDs = workspace.bonsplitController.tabs(inPane: paneID).compactMap { tab -> UUID? in
                guard let panelID = workspace.panelIdFromSurfaceId(tab.id),
                      workspace.terminalPanel(for: panelID) != nil else {
                    return nil
                }
                paneIDByTerminalID[panelID] = paneID.id
                return panelID
            }
            let selectedTerminalID = workspace.bonsplitController.selectedTab(inPane: paneID)
                .flatMap { workspace.panelIdFromSurfaceId($0.id) }
                .flatMap { workspace.terminalPanel(for: $0)?.id }
            paneListValues.append(.init(id: paneID.id, spatialIndex: spatialIndex, terminalIDs: terminalIDs))
            panePayloadValues.append(.init(
                id: paneID.id,
                spatialIndex: spatialIndex,
                isFocused: paneID.id == focusedPaneID,
                terminalIDs: terminalIDs
            ))
            paneFocusValues.append(.init(id: paneID.id, selectedTerminalID: selectedTerminalID))
        }

        let orderedPanelIDs = workspace.orderedPanelIds
        let terminalValues = orderedPanelIDs.compactMap { panelID -> TerminalPayloadValue? in
            guard let terminal = workspace.terminalPanel(for: panelID) else { return nil }
            let localDirectory = [terminal.directory, terminal.requestedWorkingDirectory]
                .compactMap { raw -> String? in
                    guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                    return raw
                }
                .first
            let directory = workspace.effectivePanelDirectory(
                panelId: terminal.id,
                localFallback: localDirectory
            )
            return .init(
                list: .init(
                    id: terminal.id,
                    title: workspace.panelTitle(panelId: terminal.id) ?? terminal.displayTitle,
                    currentDirectory: directory,
                    paneID: paneIDByTerminalID[terminal.id],
                    canClose: workspace.panels.count > 1 && !workspace.pinnedPanelIds.contains(terminal.id),
                    requiresCloseConfirmation: workspace.panelNeedsConfirmClose(panelId: terminal.id),
                    isReady: terminal.surface.surface != nil
                ),
                isFocused: terminal.id == workspace.focusedPanelId
            )
        }
        let surfaces = orderedPanelIDs.map {
            SurfaceListValue(
                id: $0,
                title: workspace.panelTitle(panelId: $0),
                reportedDirectory: workspace.reportedPanelDirectory(panelId: $0)
            )
        }
        let panelDirectories = workspace.panelDirectories.keys
            .sorted { $0.uuidString < $1.uuidString }
            .map { PanelDirectoryValue(id: $0, directory: workspace.panelDirectories[$0]) }
        list = .init(
            schemaVersion: Self.schemaVersion,
            id: workspace.id,
            title: workspace.title,
            isPinned: workspace.isPinned,
            groupID: workspace.groupId,
            previewSignature: previewSignature,
            orderedPanelIDs: orderedPanelIDs,
            pinnedPanelIDs: workspace.pinnedPanelIds.sorted { $0.uuidString < $1.uuidString },
            panes: paneListValues,
            terminals: terminalValues.map(\.list),
            surfaces: surfaces,
            currentDirectory: workspace.presentedCurrentDirectory,
            panelDirectories: panelDirectories
        )
        focus = .init(
            schemaVersion: Self.schemaVersion,
            workspaceID: workspace.id,
            focusedPaneID: focusedPaneID,
            selectedTerminalID: workspace.focusedTerminalPanel?.id,
            paneSelections: paneFocusValues
        )
        panes = panePayloadValues
        terminals = terminalValues
    }
}

struct MobileWorkspaceListProjection: Hashable {
    struct GroupValue: Hashable {
        let id: UUID
        let name: String
        let isCollapsed: Bool
        let isPinned: Bool
        let anchorWorkspaceID: UUID?
    }

    let schemaVersion: Int
    let selectedTabID: UUID?
    let groups: [GroupValue]
    let workspaces: [MobileWorkspaceHierarchyProjection.ListValue]

    @MainActor
    init(
        tabs: [Workspace],
        groups: [WorkspaceGroup],
        selectedTabID: UUID?,
        previewSignatures: [UUID: Int]
    ) {
        schemaVersion = MobileWorkspaceHierarchyProjection.schemaVersion
        self.selectedTabID = selectedTabID
        self.groups = groups.map {
            .init(
                id: $0.id,
                name: $0.name,
                isCollapsed: $0.isCollapsed,
                isPinned: $0.isPinned,
                anchorWorkspaceID: $0.anchorWorkspaceId
            )
        }
        workspaces = tabs.map {
            MobileWorkspaceHierarchyProjection(
                workspace: $0,
                previewSignature: previewSignatures[$0.id]
            ).list
        }
    }
}

/// Watches `TabManager.tabs` (and each workspace's panels publisher) and emits
/// `workspace.updated` to subscribed mobile clients whenever the iOS-facing
/// shape of the workspace list materially changes. Replaces per-RPC emit hooks
/// Any mutation surface (UI new-tab, keyboard shortcut, drag-reorder,
/// debug-cli, session restore, etc.) automatically syncs because we observe
/// the `@Published` source of truth instead of trying to catch every caller.
@MainActor
final class MobileWorkspaceListObserver {
    private weak var tabManager: TabManager?
    /// The app-global notification store, source of each workspace's last-activity
    /// preview line. Weak because the store is app-global and outlives this
    /// observer; the weak reference keeps the observer from extending the store's
    /// lifetime, mirroring how `tabManager` is held.
    private weak var notificationStore: TerminalNotificationStore?
    private var tabsCancellable: AnyCancellable?
    private var selectionCancellable: AnyCancellable?
    private var focusedSurfaceTask: Task<Void, Never>?
    private var groupsCancellable: AnyCancellable?
    private var notificationsCancellable: AnyCancellable?
    private var unreadIndicatorsCancellable: AnyCancellable?
    private var perWorkspaceCancellables: [UUID: AnyCancellable] = [:]
    private var focusedHierarchyProjections: [UUID: MobileWorkspaceHierarchyProjection.FocusValue] = [:]
    private var lastListProjection: MobileWorkspaceListProjection?
    /// Throttle window with `latest: true`. First event in a burst emits
    /// immediately (iPhone gets the change in milliseconds), subsequent
    /// events within the window collapse to one trailing emit carrying the
    /// final state. So a single action is instant; a burst caps at ~1 emit
    /// per 80 ms. Hash-diff suppresses no-op rebroadcasts.
    private let throttleMilliseconds: Int = 80

    init(tabManager: TabManager, notificationStore: TerminalNotificationStore? = nil) {
        self.tabManager = tabManager
        self.notificationStore = notificationStore
        #if DEBUG
        cmuxDebugLog("mobile.observer init tabs=\(tabManager.tabs.count)")
        #endif
        attach(to: tabManager)
    }

    deinit {
        focusedSurfaceTask?.cancel()
    }

    private func attach(to tabManager: TabManager) {
        // Initial snapshot. Every observer's first emit is unconditional so
        // freshly-paired clients see the current state without waiting for
        // the first mutation.
        focusedHierarchyProjections = Dictionary(uniqueKeysWithValues: tabManager.tabs.map {
            ($0.id, MobileWorkspaceHierarchyProjection(workspace: $0).focus)
        })
        emitIfNeeded(force: true)

        tabsCancellable = tabManager.tabsPublisher
            .throttle(for: .milliseconds(throttleMilliseconds), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in
                guard let self, let tabManager = self.tabManager else { return }
                #if DEBUG
                cmuxDebugLog("mobile.observer tabs sink fired count=\(tabManager.tabs.count)")
                #endif
                self.refreshPerWorkspaceSubscriptions(tabs: tabManager.tabs)
                self.emitIfNeeded(force: false)
            }
        // Selection changes (Mac user clicks a different sidebar tab) need
        // to push to iPhone too. iPhone's selectedWorkspaceID drives which
        // terminal it displays.
        selectionCancellable = tabManager.selectedTabIdPublisher
            .throttle(for: .milliseconds(throttleMilliseconds), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in
                self?.emitIfNeeded(force: false)
            }
        // Bonsplit pane focus and tab selection are serialized to iOS but are
        // not @Published Workspace state. The existing deferred focus broadcast
        // fires after selection converges, so use it as the scoped wakeup and
        // let summaryHash suppress duplicate notifications.
        focusedSurfaceTask = Task { @MainActor [weak self] in
            for await notification in NotificationCenter.default.notifications(named: .ghosttyDidFocusSurface) {
                guard let self,
                      let workspaceID = notification.userInfo?[GhosttyNotificationKey.tabId] as? UUID,
                      let workspace = self.tabManager?.tabs.first(where: { $0.id == workspaceID }) else {
                    continue
                }
                self.emitFocusedHierarchyUpdateIfNeeded(for: workspace)
            }
        }
        // Group structure (order, name, collapse/pin, anchor, membership) is
        // iOS-facing: the phone renders collapsible group sections. A pure
        // collapse/expand or group rename need not change the tab set, so without
        // observing `$workspaceGroups` the phone would never learn a group was
        // collapsed from the Mac (or from the phone's own collapse RPC, which is
        // authoritative + re-fetch based, not optimistic).
        groupsCancellable = tabManager.workspaceGroupsPublisher
            .throttle(for: .milliseconds(throttleMilliseconds), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in
                self?.emitIfNeeded(force: false)
            }
        // Last-activity preview lines come from the notification store, which is
        // not part of the TabManager graph. A new notification (or a cleared one)
        // changes a row's preview + relative time without touching the tab set,
        // groups, panels, or title, so observe `$notifications` to push it.
        // Marking a notification read also flows through `$notifications` (the
        // mutated element re-publishes the array), which the unread flag in the
        // per-workspace signature turns into a hash change.
        //
        // Ordering invariant: `@Published` emits from `willSet`, but every sink
        // here reads the store's post-`didSet` state (latestNotification /
        // unread indexes) rather than the emitted value. That is safe because
        // `throttle(for:scheduler: RunLoop.main)` always hops through the run
        // loop, so delivery happens after the assignment (and its `didSet`
        // index rebuild) completes; it never fires synchronously from
        // `willSet`. The pre-existing `$tabs` / `$selectedTabId` sinks rely on
        // the same property.
        notificationsCancellable = notificationStore?.$notifications
            .throttle(for: .milliseconds(throttleMilliseconds), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in
                self?.emitIfNeeded(force: false)
            }
        // Workspace-level unread indicators (manual mark-unread, panel-derived,
        // session-restored) live in their own published sets, not in
        // `notifications`. Toggling one changes the phone's unread dot without
        // touching anything else this observer watches, so merge all three here.
        if let notificationStore {
            unreadIndicatorsCancellable = Publishers.MergeMany(
                notificationStore.$manualUnreadWorkspaceIds.map { _ in () }.eraseToAnyPublisher(),
                notificationStore.$panelDerivedUnreadWorkspaceIds.map { _ in () }.eraseToAnyPublisher(),
                notificationStore.$restoredUnreadWorkspaceIds.map { _ in () }.eraseToAnyPublisher()
            )
            .throttle(for: .milliseconds(throttleMilliseconds), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in
                self?.emitIfNeeded(force: false)
            }
        }

        refreshPerWorkspaceSubscriptions(tabs: tabManager.tabs)
    }

    private func currentPreviewSignatures(for tabs: [Workspace]) -> [UUID: Int] {
        Self.previewSignatures(for: tabs, notificationStore: notificationStore)
    }

    /// A per-workspace signature of the notification-store state the mobile
    /// payload serializes: the latest-notification preview (its id + timestamp)
    /// and the workspace's unread flag. The hash changes when a new notification
    /// arrives, the latest one is cleared, or the workspace flips between read
    /// and unread (mark-read, manual mark-unread, panel-derived or restored
    /// indicators). A workspace with no notification and no unread state is
    /// absent from the map. Empty when no store is attached (tests, or a build
    /// with notifications unavailable).
    static func previewSignatures(
        for tabs: [Workspace],
        notificationStore: TerminalNotificationStore?
    ) -> [UUID: Int] {
        let signpost = MobileWorkspaceObserverSignposts.begin("mobile-workspace-preview-signatures", "workspaces=\(tabs.count) hasStore=\(notificationStore != nil)"); defer { MobileWorkspaceObserverSignposts.end(signpost) }
        guard let notificationStore else { return [:] }
        var signatures: [UUID: Int] = [:]
        for workspace in tabs {
            let latest = notificationStore.latestNotification(forTabId: workspace.id)
            let isUnread = notificationStore.workspaceIsUnread(forTabId: workspace.id)
            guard latest != nil || isUnread else { continue }
            var hasher = Hasher()
            hasher.combine(latest?.id)
            hasher.combine(latest?.createdAt)
            hasher.combine(isUnread)
            signatures[workspace.id] = hasher.finalize()
        }
        return signatures
    }

    private func refreshPerWorkspaceSubscriptions(tabs: [Workspace]) {
        let currentIDs = Set(tabs.map(\.id))
        // Drop subscriptions for workspaces that vanished.
        for id in perWorkspaceCancellables.keys where !currentIDs.contains(id) {
            perWorkspaceCancellables.removeValue(forKey: id)
            focusedHierarchyProjections.removeValue(forKey: id)
        }
        // Merge the per-workspace publishers behind the mobile workspace
        // list: terminal set, terminal titles, workspace title, and displayed
        // directory fields. Directory changes can arrive from shell prompt
        // updates without changing the terminal set.
        for workspace in tabs where perWorkspaceCancellables[workspace.id] == nil {
            focusedHierarchyProjections[workspace.id] = MobileWorkspaceHierarchyProjection(workspace: workspace).focus
            let publishers: [AnyPublisher<Void, Never>] = [
                workspace.panelsPublisher.map { _ in () }.eraseToAnyPublisher(),
                workspace.$panelTitles.map { _ in () }.eraseToAnyPublisher(),
                // Renaming a terminal sets `panelCustomTitles` (not `panelTitles`),
                // so without this a terminal rename never re-emits to the phone.
                workspace.$panelCustomTitles.map { _ in () }.eraseToAnyPublisher(),
                workspace.$title.map { _ in () }.eraseToAnyPublisher(),
                // Pin/unpin is iOS-facing (the phone shows a Pinned section), and
                // a pure pin toggle need not change the panel set or title, so
                // without this the phone never learns the workspace was pinned.
                workspace.$isPinned.map { _ in () }.eraseToAnyPublisher(),
                // Pinning an individual surface changes its closeability without
                // necessarily changing order, panel membership, or workspace pin.
                workspace.$pinnedPanelIds.map { _ in () }.eraseToAnyPublisher(),
                // Group membership is iOS-facing (the phone nests members under
                // their group header). Moving a workspace into or out of a group
                // mutates only this workspace's `groupId`; it need not change the
                // tab set, `workspaceGroups`, the panel set, or the title, so
                // without this the phone never learns the membership changed.
                workspace.$groupId.map { _ in () }.eraseToAnyPublisher(),
                workspace.$currentDirectory.map { _ in () }.eraseToAnyPublisher(),
                workspace.$panelDirectories.map { _ in () }.eraseToAnyPublisher(),
                workspace.currentDirectoryChangeRevisionPublisher()
                    .map { _ in () }
                    .eraseToAnyPublisher(),
                workspace.$activeRemoteTerminalSessionCount.map { _ in () }.eraseToAnyPublisher(),
                // Pure drag-reorders change spatial order without changing the panel
                // set; bonsplit selection state is not `@Published`, so this counter
                // is the only signal the observer gets for a reorder.
                workspace.paneLayoutVersionPublisher.map { _ in () }.eraseToAnyPublisher(),
            ]
            let merged = Publishers.MergeMany(publishers)
                .throttle(for: .milliseconds(throttleMilliseconds), scheduler: RunLoop.main, latest: true)
            perWorkspaceCancellables[workspace.id] = merged.sink { [weak self] _ in
                self?.emitIfNeeded(force: false)
            }
        }
    }

    private func emitFocusedHierarchyUpdateIfNeeded(for workspace: Workspace) {
        let projection = MobileWorkspaceHierarchyProjection(workspace: workspace).focus
        guard focusedHierarchyProjections[workspace.id] != projection else { return }
        focusedHierarchyProjections[workspace.id] = projection
        mobileWorkspaceObserverLog.debug(
            "emitting workspace.focused hierarchy workspace=\(workspace.id, privacy: .public)"
        )
        MobileHostService.shared.emitEvent(topic: "workspace.focused", payload: projection.eventPayload)
    }

    static func focusedHierarchySignature(for workspace: Workspace) -> Int {
        var hasher = Hasher()
        hasher.combine(MobileWorkspaceHierarchyProjection(workspace: workspace).focus)
        return hasher.finalize()
    }

    private func emitIfNeeded(force: Bool) {
        let signpost = MobileWorkspaceObserverSignposts.begin("mobile-workspace-emit-if-needed", "force=\(force)"); defer { MobileWorkspaceObserverSignposts.end(signpost) }
        guard let tabManager else { return }
        let projection = MobileWorkspaceListProjection(
            tabs: tabManager.tabs,
            groups: tabManager.workspaceGroups,
            selectedTabID: tabManager.selectedTabId,
            previewSignatures: currentPreviewSignatures(for: tabManager.tabs)
        )
        if !force, projection == lastListProjection {
            #if DEBUG
            cmuxDebugLog("mobile.observer skip: projection unchanged tabs=\(tabManager.tabs.count)")
            #endif
            return
        }
        lastListProjection = projection
        mobileWorkspaceObserverLog.debug("emitting workspace.updated")
        #if DEBUG
        cmuxDebugLog("mobile.observer EMIT workspace.updated tabs=\(tabManager.tabs.count) force=\(force)")
        #endif
        MobileHostService.shared.emitEvent(topic: "workspace.updated", payload: [:])
    }

    /// Stable hash of the iOS-facing shape: workspace ids + titles + their
    /// panels grouped by pane + each panel's displayed
    /// (custom-aware) title and directory. Mutations that don't show up on the
    /// mobile list (pane geometry and scrollback content) don't trip the event.
    ///
    /// The panel ids are hashed in `orderedPanelIds` order (not the sorted set),
    /// so a pure drag-reorder, which changes the spatial order but not the id set,
    /// produces a different hash and re-emits to the phone. Titles are hashed via
    /// `panelTitle(panelId:)` so a custom terminal rename (which sets
    /// `panelCustomTitles`, not `panelTitles`) is detected too.
    /// `previewSignatures` maps a workspace id to a hash of its latest-notification
    /// preview (notification id + timestamp). Folding it in means a new notification
    /// (or a cleared one) re-emits to the phone, which renders the preview + relative
    /// time. Workspaces with no notification are simply absent from the map.
    static func summaryHash(
        for tabs: [Workspace],
        groups: [WorkspaceGroup],
        selectedTabID: UUID?,
        previewSignatures: [UUID: Int]
    ) -> Int {
        let signpost = MobileWorkspaceObserverSignposts.begin("mobile-workspace-summary-hash", "workspaces=\(tabs.count) groups=\(groups.count) previews=\(previewSignatures.count) selected=\(selectedTabID.map { String($0.uuidString.prefix(5)) } ?? "nil")"); defer { MobileWorkspaceObserverSignposts.end(signpost) }
        let projection = MobileWorkspaceListProjection(
            tabs: tabs,
            groups: groups,
            selectedTabID: selectedTabID,
            previewSignatures: previewSignatures
        )
        var hasher = Hasher()
        hasher.combine(projection)
        return hasher.finalize()
    }

}
