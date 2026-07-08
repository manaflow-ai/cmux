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
    /// `@Observable` watches on the `WorkspacesModel` (tabs / selection /
    /// groups), replacing the retired `tabsPublisher` / `selectedTabIdPublisher`
    /// / `workspaceGroupsPublisher` Combine bridges. Each fires on a MainActor
    /// hop after the corresponding `tabs` / `selectedTabId` / `workspaceGroups`
    /// mutation and pushes into a throttled `PassthroughSubject` so the iOS-facing
    /// emit cadence (first event instant, bursts coalesced to one trailing emit
    /// per `throttleMilliseconds`) is byte-identical to the bridges' former
    /// `.throttle(scheduler: RunLoop.main, latest: true)`.
    private var tabsObservation: WorkspacesObservation?
    private var selectionObservation: WorkspacesObservation?
    private var groupsObservation: WorkspacesObservation?
    private let tabsChanged = PassthroughSubject<Void, Never>()
    private let selectionChanged = PassthroughSubject<Void, Never>()
    private let groupsChanged = PassthroughSubject<Void, Never>()
    private var tabsChangedCancellable: AnyCancellable?
    private var selectionChangedCancellable: AnyCancellable?
    private var groupsChangedCancellable: AnyCancellable?
    private var notificationsCancellable: AnyCancellable?
    private var unreadIndicatorsCancellable: AnyCancellable?
    private var perWorkspaceCancellables: [UUID: AnyCancellable] = [:]
    private var lastSummaryHash: Int = 0
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

    private func attach(to tabManager: TabManager) {
        // Initial snapshot. Every observer's first emit is unconditional so
        // freshly-paired clients see the current state without waiting for
        // the first mutation.
        let initial = Self.summaryHash(
            for: tabManager.tabs,
            groups: tabManager.workspaceGroups,
            selectedTabID: tabManager.selectedTabId,
            previewSignatures: currentPreviewSignatures(for: tabManager.tabs)
        )
        lastSummaryHash = initial
        emitIfNeeded(force: true)

        // Each `@Observable` watch pushes into its own throttled subject so the
        // tabs / selection / groups streams coalesce independently, exactly as
        // the three separate `.throttle` bridges did. The watch reads committed
        // post-change state on the MainActor hop, so the throttled handler reads
        // `tabManager.tabs` rather than a willSet-time emitted value (the bridges'
        // `.throttle(scheduler: RunLoop.main)` already deferred past the willSet).
        tabsChangedCancellable = tabsChanged
            .throttle(for: .milliseconds(throttleMilliseconds), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] in
                guard let self, let tabManager = self.tabManager else { return }
                #if DEBUG
                cmuxDebugLog("mobile.observer tabs sink fired count=\(tabManager.tabs.count)")
                #endif
                self.refreshPerWorkspaceSubscriptions(tabs: tabManager.tabs)
                self.emitIfNeeded(force: false)
            }
        tabsObservation = tabManager.workspaces.observeTabs { [weak self] in
            self?.tabsChanged.send(())
        }
        // Selection changes (Mac user clicks a different sidebar tab) need
        // to push to iPhone too. iPhone's selectedWorkspaceID drives which
        // terminal it displays.
        selectionChangedCancellable = selectionChanged
            .throttle(for: .milliseconds(throttleMilliseconds), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] in
                self?.emitIfNeeded(force: false)
            }
        selectionObservation = tabManager.workspaces.observeSelectedTabId { [weak self] in
            self?.selectionChanged.send(())
        }
        // Group structure (order, name, collapse/pin, anchor, membership) is
        // iOS-facing: the phone renders collapsible group sections. A pure
        // collapse/expand or group rename need not change the tab set, so without
        // observing `workspaceGroups` the phone would never learn a group was
        // collapsed from the Mac (or from the phone's own collapse RPC, which is
        // authoritative + re-fetch based, not optimistic).
        groupsChangedCancellable = groupsChanged
            .throttle(for: .milliseconds(throttleMilliseconds), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] in
                self?.emitIfNeeded(force: false)
            }
        groupsObservation = tabManager.workspaces.observeWorkspaceGroups { [weak self] in
            self?.groupsChanged.send(())
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
        }
        // Merge the per-workspace publishers behind the mobile workspace
        // list: terminal set, terminal titles, workspace title, and displayed
        // directory fields. Directory changes can arrive from shell prompt
        // updates without changing the terminal set.
        for workspace in tabs where perWorkspaceCancellables[workspace.id] == nil {
            let publishers: [AnyPublisher<Void, Never>] = [
                workspace.panelsPublisher.map { _ in () }.eraseToAnyPublisher(),
                workspace.panelTitlesPublisher.map { _ in () }.eraseToAnyPublisher(),
                // Renaming a terminal sets `panelCustomTitles` (not `panelTitles`),
                // so without this a terminal rename never re-emits to the phone.
                workspace.panelCustomTitlesPublisher.map { _ in () }.eraseToAnyPublisher(),
                workspace.titlePublisher.map { _ in () }.eraseToAnyPublisher(),
                // Pin/unpin is iOS-facing (the phone shows a Pinned section), and
                // a pure pin toggle need not change the panel set or title, so
                // without this the phone never learns the workspace was pinned.
                workspace.isPinnedPublisher.map { _ in () }.eraseToAnyPublisher(),
                // Group membership is iOS-facing (the phone nests members under
                // their group header). Moving a workspace into or out of a group
                // mutates only this workspace's `groupId`; it need not change the
                // tab set, `workspaceGroups`, the panel set, or the title, so
                // without this the phone never learns the membership changed.
                workspace.groupIdPublisher.map { _ in () }.eraseToAnyPublisher(),
                workspace.currentDirectoryPublisher.map { _ in () }.eraseToAnyPublisher(),
                workspace.panelDirectoriesPublisher.map { _ in () }.eraseToAnyPublisher(),
                workspace.currentDirectoryChangeRevisionPublisher()
                    .map { _ in () }
                    .eraseToAnyPublisher(),
                workspace.activeRemoteTerminalSessionCountPublisher.map { _ in () }.eraseToAnyPublisher(),
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

    private func emitIfNeeded(force: Bool) {
        let signpost = MobileWorkspaceObserverSignposts.begin("mobile-workspace-emit-if-needed", "force=\(force)"); defer { MobileWorkspaceObserverSignposts.end(signpost) }
        guard let tabManager else { return }
        let hash = Self.summaryHash(
            for: tabManager.tabs,
            groups: tabManager.workspaceGroups,
            selectedTabID: tabManager.selectedTabId,
            previewSignatures: currentPreviewSignatures(for: tabManager.tabs)
        )
        if !force, hash == lastSummaryHash {
            #if DEBUG
            cmuxDebugLog("mobile.observer skip: hash unchanged=\(hash) tabs=\(tabManager.tabs.count)")
            #endif
            return
        }
        lastSummaryHash = hash
        mobileWorkspaceObserverLog.debug("emitting workspace.updated (hash=\(hash, privacy: .public))")
        #if DEBUG
        cmuxDebugLog("mobile.observer EMIT workspace.updated hash=\(hash) tabs=\(tabManager.tabs.count) force=\(force)")
        #endif
        MobileHostService.shared.emitEvent(topic: "workspace.updated", payload: [:])
    }

    /// Stable hash of the iOS-facing shape: workspace ids + titles + their
    /// panels in spatial order + each panel's displayed (custom-aware) title and
    /// directory. Mutations that don't show up on the mobile list (pane geometry,
    /// scrollback content, focus only) don't trip the event, so we don't fan out
    /// on every keystroke.
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
    private static func summaryHash(
        for tabs: [Workspace],
        groups: [WorkspaceGroup],
        selectedTabID: UUID?,
        previewSignatures: [UUID: Int]
    ) -> Int {
        let signpost = MobileWorkspaceObserverSignposts.begin("mobile-workspace-summary-hash", "workspaces=\(tabs.count) groups=\(groups.count) previews=\(previewSignatures.count) selected=\(selectedTabID.map { String($0.uuidString.prefix(5)) } ?? "nil")"); defer { MobileWorkspaceObserverSignposts.end(signpost) }
        var hasher = Hasher()
        hasher.combine(tabs.count)
        hasher.combine(selectedTabID)
        // Group sections are iOS-facing. Hash group order + the fields the phone
        // renders (name, collapse, pin, anchor) so a pure collapse/expand, rename,
        // or reorder re-emits to the phone. Membership is already covered by each
        // workspace's `groupId`, hashed in the per-workspace loop below.
        hasher.combine(groups.count)
        for group in groups {
            hasher.combine(group.id)
            hasher.combine(group.name)
            hasher.combine(group.isCollapsed)
            hasher.combine(group.isPinned)
            hasher.combine(group.anchorWorkspaceId)
        }
        for workspace in tabs {
            hasher.combine(workspace.id)
            hasher.combine(workspace.title)
            hasher.combine(workspace.isPinned)
            // Group membership is iOS-facing (the phone nests members under the
            // group header), and a pure move-into/out-of-group need not change the
            // panel set or title, so hash it here.
            hasher.combine(workspace.groupId)
            // Last-activity preview line + timestamp shown on each row. Sourced
            // from the notification store (not the TabManager graph), so it is
            // folded in here as a precomputed signature.
            hasher.combine(previewSignatures[workspace.id])
            // Spatial order is significant: hash the ordered id sequence so a
            // reorder of the same panel set changes the hash.
            let panelIDs = workspace.orderedPanelIds
            hasher.combine(panelIDs)
            for id in panelIDs {
                hasher.combine(workspace.panelTitle(panelId: id))
                hasher.combine(workspace.reportedPanelDirectory(panelId: id))
            }
            hasher.combine(workspace.presentedCurrentDirectory)
            // Hash every panelDirectories entry (including ids not yet in
            // `panels`) so a directory update is detected even before its panel
            // registers. The ordered loop above already covers in-panel
            // directories; this preserves the pre-existing behavior the mobile
            // hash test relies on.
            for id in workspace.panelDirectories.keys.sorted() {
                hasher.combine(id)
                hasher.combine(workspace.panelDirectories[id])
            }
        }
        return hasher.finalize()
    }

    #if DEBUG
    static func summaryHashForTesting(
        tabs: [Workspace],
        groups: [WorkspaceGroup] = [],
        selectedTabID: UUID?,
        previewSignatures: [UUID: Int] = [:]
    ) -> Int {
        summaryHash(
            for: tabs,
            groups: groups,
            selectedTabID: selectedTabID,
            previewSignatures: previewSignatures
        )
    }
    #endif
}
