import CMUXMobileCore
import Foundation

/// Mac-side owner of mobile state sync v2 (`docs/mobile-state-sync-v2.md`).
///
/// Holds the versioned record store, rebuilds the typed iOS-facing rows from
/// the same sources the legacy `mobile.workspace.list` payload reads, and
/// broadcasts `mobile.sync.delta` events carrying only the rows a change tick
/// actually touched. The legacy empty-payload `workspace.updated` event keeps
/// firing unchanged for released phones; v2 phones subscribe to the delta
/// topic and stop re-fetching full lists.
@MainActor
final class MobileStateSyncHost {
    static let shared = MobileStateSyncHost()

    /// Event topic v2 phones subscribe to through `mobile.events.subscribe`.
    static let deltaTopic = "mobile.sync.delta"

    let store = MobileStateSyncStore()

    /// Sanitized-preview cache keyed by workspace. The sanitizer walks up to
    /// ~2K scalars of notification text per row; caching on the notification
    /// identity means a rebuild only re-sanitizes rows whose latest
    /// notification actually changed.
    private struct PreviewCacheEntry {
        let notificationID: UUID
        let createdAt: Date
        let text: String?
    }

    private var previewCache: [UUID: PreviewCacheEntry] = [:]

    /// Observer tick entry point: cheap no-op unless some phone subscribed to
    /// the delta topic (the store then also stays cold until the first
    /// `mobile.sync.fetch` populates it).
    func broadcastIfSubscribed() {
        guard MobileHostService.hasEventSubscribers(topic: Self.deltaTopic) else { return }
        refreshAndBroadcast()
    }

    /// `mobile.sync.fetch` handler. Refreshes the store first so the answer is
    /// current even when no observer tick has fired yet, and so the refresh's
    /// delta event (if any) reaches already-subscribed phones and keeps their
    /// cursors contiguous with this response's revisions.
    func fetch(params: [String: Any]) -> TerminalController.V2CallResult {
        let request: MobileSyncFetchRequest
        do {
            request = try MobileSyncFrameCoder().decode(MobileSyncFetchRequest.self, fromJSONObject: params)
        } catch {
            return .err(code: "invalid_params", message: "Missing or invalid collections", data: nil)
        }
        guard !request.collections.isEmpty else {
            return .err(code: "invalid_params", message: "Missing or invalid collections", data: nil)
        }
        refreshAndBroadcast()
        let response = store.fetchResponse(for: request)
        guard let payload = try? MobileSyncFrameCoder().jsonObject(from: response) else {
            return .err(code: "internal_error", message: "Failed to encode sync response", data: nil)
        }
        return .ok(payload)
    }

    /// Rebuilds the typed rows, diffs them into the store, and broadcasts one
    /// delta event per changed collection. No-op frames emit nothing.
    private func refreshAndBroadcast() {
        let rows = buildRows()
        if let change = store.workspaces.apply(rows: rows.workspaces) {
            emit(collection: .workspaces, change: change)
        }
        if let change = store.groups.apply(rows: rows.groups) {
            emit(collection: .groups, change: change)
        }
    }

    private func emit<Record: MobileSyncRecord>(
        collection: MobileSyncCollectionID,
        change: MobileSyncCollectionChange<Record>
    ) {
        let event = MobileSyncDeltaEvent(
            epoch: store.epoch,
            collection: collection,
            fromRev: change.fromRev,
            toRev: change.toRev,
            records: change.records,
            removedIDs: change.removedIDs
        )
        guard let payload = try? MobileSyncFrameCoder().jsonObject(from: event) else { return }
        MobileHostService.shared.emitEvent(topic: Self.deltaTopic, payload: payload)
    }

    // MARK: - Row building

    /// Builds the flattened cross-window rows, mirroring the enumeration and
    /// field semantics of `v2MobileWorkspaceList`'s all-windows branch (same
    /// sources, same fallbacks) so the two views of the list can never
    /// disagree on content, only on transport shape.
    private func buildRows() -> (workspaces: [WorkspaceSyncRecord], groups: [GroupSyncRecord]) {
        guard let app = AppDelegate.shared else {
            return ([], [])
        }
        let controller = TerminalController.shared
        let selectedWorkspaceID = app.currentScriptableMainWindow()?.tabManager.selectedTabId
        let notificationStore = app.notificationStore

        var workspaceRows: [WorkspaceSyncRecord] = []
        var groupRows: [GroupSyncRecord] = []
        var seenWindowIDs: Set<UUID> = []
        var seenWorkspaceIDs: Set<UUID> = []
        var seenGroupIDs: Set<UUID> = []
        var liveWorkspaceIDs: Set<UUID> = []

        for summary in app.listMainWindowSummaries() {
            guard seenWindowIDs.insert(summary.windowId).inserted else { continue }
            guard let windowTabManager = app.tabManagerFor(windowId: summary.windowId) else { continue }
            for group in windowTabManager.workspaceGroups where seenGroupIDs.insert(group.id).inserted {
                groupRows.append(
                    GroupSyncRecord(
                        id: group.id.uuidString,
                        name: group.name,
                        isCollapsed: group.isCollapsed,
                        isPinned: group.isPinned,
                        anchorWorkspaceID: group.anchorWorkspaceId.uuidString,
                        sortIndex: groupRows.count
                    )
                )
            }
            for workspace in windowTabManager.tabs where seenWorkspaceIDs.insert(workspace.id).inserted {
                liveWorkspaceIDs.insert(workspace.id)
                workspaceRows.append(
                    workspaceRow(
                        workspace: workspace,
                        windowID: summary.windowId,
                        isSelected: workspace.id == selectedWorkspaceID,
                        sortIndex: workspaceRows.count,
                        controller: controller,
                        notificationStore: notificationStore
                    )
                )
            }
        }
        previewCache = previewCache.filter { liveWorkspaceIDs.contains($0.key) }
        return (workspaceRows, groupRows)
    }

    func workspaceRow(
        workspace: Workspace,
        windowID: UUID,
        isSelected: Bool,
        sortIndex: Int,
        controller: TerminalController,
        notificationStore: TerminalNotificationStore?
    ) -> WorkspaceSyncRecord {
        let terminals = controller.mobileTerminalPanels(in: workspace).map { terminal -> WorkspaceSyncRecord.Terminal in
            let terminalDirectory = workspace.effectivePanelDirectory(
                panelId: terminal.id,
                localFallback: controller.mobileNonEmpty(terminal.directory)
                    ?? controller.mobileNonEmpty(terminal.requestedWorkingDirectory)
            )
            return WorkspaceSyncRecord.Terminal(
                id: terminal.id.uuidString,
                title: workspace.panelTitle(panelId: terminal.id) ?? terminal.displayTitle,
                currentDirectory: terminalDirectory,
                isReady: terminal.surface.surface != nil,
                isFocused: terminal.id == workspace.focusedPanelId
            )
        }
        let latestNotification = notificationStore?.latestNotification(forTabId: workspace.id)
        let preview = cachedPreview(workspaceID: workspace.id, latestNotification: latestNotification)
        return WorkspaceSyncRecord(
            id: workspace.id.uuidString,
            windowID: windowID.uuidString,
            title: workspace.title,
            currentDirectory: workspace.presentedCurrentDirectory,
            isSelected: isSelected,
            isPinned: workspace.isPinned,
            groupID: workspace.groupId?.uuidString,
            preview: preview?.text,
            previewAt: preview?.epochSeconds,
            lastActivityAt: (latestNotification?.createdAt ?? workspace.createdAt).timeIntervalSince1970,
            hasUnread: notificationStore?.workspaceIsUnread(forTabId: workspace.id) ?? false,
            sortIndex: sortIndex,
            terminals: terminals,
            surfaces: controller.mobileSurfaceDescriptors(in: workspace)
        )
    }

    /// The legacy path's `mobileWorkspacePreview` semantics with a cache: the
    /// sanitizer runs only when the workspace's latest notification identity
    /// changed since the last rebuild.
    private func cachedPreview(
        workspaceID: UUID,
        latestNotification: TerminalNotification?
    ) -> (text: String, epochSeconds: Double)? {
        guard let notification = latestNotification else {
            previewCache[workspaceID] = nil
            return nil
        }
        if let cached = previewCache[workspaceID],
           cached.notificationID == notification.id,
           cached.createdAt == notification.createdAt {
            guard let text = cached.text else { return nil }
            return (text, notification.createdAt.timeIntervalSince1970)
        }
        let raw = notification.body.isEmpty ? notification.title : notification.body
        let text = TerminalController.mobilePreviewSanitize(raw)
        previewCache[workspaceID] = PreviewCacheEntry(
            notificationID: notification.id,
            createdAt: notification.createdAt,
            text: text
        )
        guard let text else { return nil }
        return (text, notification.createdAt.timeIntervalSince1970)
    }
}

extension TerminalController {
    /// `mobile.sync.fetch`: cursor-based fetch for mobile state sync v2.
    func v2MobileSyncFetch(params: [String: Any]) -> V2CallResult {
        MobileStateSyncHost.shared.fetch(params: params)
    }
}
