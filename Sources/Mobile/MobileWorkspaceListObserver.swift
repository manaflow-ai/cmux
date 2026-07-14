import Combine
import CmuxWorkspaces
import Foundation
import OSLog

private let mobileWorkspaceObserverLog = Logger(subsystem: "dev.cmux", category: "mobile-workspace-observer")

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
    private var workspaceListDigestIndex = MobileWorkspaceListProjection.DigestIndex()
    private var workspacePreviewSignatures: [UUID: Int] = [:]
    private var lastListDigest: Int?
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
            ($0.id, MobileWorkspaceHierarchyProjection.FocusValue(workspace: $0))
        })
        workspacePreviewSignatures = currentPreviewSignatures(for: tabManager.tabs)
        emitIfNeeded(force: true, resampling: Set(tabManager.tabs.map(\.id)))

        tabsCancellable = tabManager.tabsPublisher
            .throttle(for: .milliseconds(throttleMilliseconds), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in
                guard let self, let tabManager = self.tabManager else { return }
                #if DEBUG
                cmuxDebugLog("mobile.observer tabs sink fired count=\(tabManager.tabs.count)")
                #endif
                self.refreshPerWorkspaceSubscriptions(tabs: tabManager.tabs)
                self.refreshPreviewSignaturesAndEmit()
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
                self?.refreshPreviewSignaturesAndEmit()
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
                self?.refreshPreviewSignaturesAndEmit()
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
            focusedHierarchyProjections[workspace.id] = MobileWorkspaceHierarchyProjection.FocusValue(
                workspace: workspace
            )
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
            let workspaceID = workspace.id
            perWorkspaceCancellables[workspace.id] = merged.sink { [weak self] _ in
                self?.emitIfNeeded(force: false, resampling: [workspaceID])
            }
        }
    }

    private func refreshPreviewSignaturesAndEmit() {
        guard let tabManager else { return }
        let next = currentPreviewSignatures(for: tabManager.tabs)
        let candidateIDs = Set(workspacePreviewSignatures.keys).union(next.keys)
        let changedIDs = Set(candidateIDs.filter {
            workspacePreviewSignatures[$0] != next[$0]
        })
        workspacePreviewSignatures = next
        emitIfNeeded(force: false, resampling: changedIDs)
    }

    private func emitFocusedHierarchyUpdateIfNeeded(for workspace: Workspace) {
        let projection = MobileWorkspaceHierarchyProjection.FocusValue(workspace: workspace)
        guard focusedHierarchyProjections[workspace.id] != projection else { return }
        focusedHierarchyProjections[workspace.id] = projection
        mobileWorkspaceObserverLog.debug(
            "emitting workspace.focused hierarchy workspace=\(workspace.id, privacy: .public)"
        )
        MobileHostService.shared.emitEvent(topic: "workspace.focused", payload: projection.eventPayload)
    }

    private func emitIfNeeded(force: Bool, resampling workspaceIDs: Set<UUID> = []) {
        let signpost = MobileWorkspaceObserverSignposts.begin("mobile-workspace-emit-if-needed", "force=\(force)"); defer { MobileWorkspaceObserverSignposts.end(signpost) }
        guard let tabManager else { return }
        let workspaceDigests = workspaceListDigestIndex.refresh(
            tabs: tabManager.tabs,
            resampling: workspaceIDs
        ) { [workspacePreviewSignatures] workspace in
            MobileWorkspaceListProjection.workspaceDigest(
                workspace: workspace,
                previewSignature: workspacePreviewSignatures[workspace.id]
            )
        }
        let digest = MobileWorkspaceListProjection.digest(
            tabs: tabManager.tabs,
            groups: tabManager.workspaceGroups,
            selectedTabID: tabManager.selectedTabId,
            workspaceDigests: workspaceDigests
        )
        if !force, digest == lastListDigest {
            #if DEBUG
            cmuxDebugLog("mobile.observer skip: projection unchanged tabs=\(tabManager.tabs.count)")
            #endif
            return
        }
        lastListDigest = digest
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
        return MobileWorkspaceListProjection.digest(
            tabs: tabs,
            groups: groups,
            selectedTabID: selectedTabID,
            previewSignatures: previewSignatures
        )
    }

}
