import CmuxMobileRPC
public import CmuxMobileShellModel
import Foundation
internal import OSLog

private let notificationFeedLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "dev.cmux.ios",
    category: "notification-feed"
)

@MainActor
extension MobileShellComposite {
    /// Refreshes the chronological feed from every currently connected capable Mac.
    ///
    /// A Mac that is offline keeps its last-known snapshot. Connected Macs that
    /// predate `notification.feed.v1` are excluded without hiding snapshots from
    /// newer or temporarily unavailable Macs.
    public func refreshNotificationFeed() async {
        let targets = notificationFeedTargets()
        if targets.isEmpty {
            recomputeNotificationFeedItems()
            notificationFeedStatus = resolvedNotificationFeedStatus()
            return
        }

        notificationFeedStatus = .loading
        let tasks = targets.compactMap { target in
            scheduleNotificationFeedRefresh(
                macDeviceID: target.macDeviceID,
                client: target.client,
                displayName: target.displayName
            )
        }
        for task in tasks {
            await task.value
        }
        recomputeNotificationFeedItems()
        notificationFeedStatus = resolvedNotificationFeedStatus()
    }

    /// Resolves feed availability for one computer picker scope. A retained
    /// snapshot stays visible while its Mac is offline, while a connected Mac
    /// without the feed capability reports that it needs an update.
    public func notificationFeedStatus(
        scopedTo macDeviceIDs: Set<String>?
    ) -> MobileNotificationFeedStatus {
        guard let macDeviceIDs, !macDeviceIDs.isEmpty else {
            return notificationFeedStatus
        }

        var connectedMacDeviceIDs = Set(secondaryMacSubscriptions.keys)
        if remoteClient != nil, let foregroundID = normalizedForegroundNotificationFeedMacID() {
            connectedMacDeviceIDs.insert(foregroundID)
        }
        let capableMacDeviceIDs = Set(notificationFeedTargets().map(\.macDeviceID))
        let hasConnectedMac = !connectedMacDeviceIDs.isDisjoint(with: macDeviceIDs)
        let hasCapableMac = !capableMacDeviceIDs.isDisjoint(with: macDeviceIDs)
        let hasSnapshot = !Set(notificationFeedSnapshotsByMac.keys).isDisjoint(with: macDeviceIDs)
        let hasSuccessfulSnapshot = !notificationFeedSuccessfulMacIDs.isDisjoint(with: macDeviceIDs)
        let isRefreshing = !Set(notificationFeedRefreshTasksByMac.keys).isDisjoint(with: macDeviceIDs)

        guard hasConnectedMac else { return .unavailable }
        guard hasCapableMac else { return .requiresMacUpdate }
        if isRefreshing, !hasSnapshot, !hasSuccessfulSnapshot { return .loading }
        if hasSnapshot || hasSuccessfulSnapshot { return .ready }
        return .unavailable
    }

    /// Marks one notification read on its owning Mac and reconciles the local snapshot.
    /// - Parameter item: The immutable feed item selected by the user.
    public func markNotificationFeedItemRead(_ item: MobileNotificationFeedItem) async {
        await setNotificationFeedItemReadState(item, isRead: true)
    }

    /// Marks one notification unread on its owning Mac and reconciles the local snapshot.
    /// - Parameter item: The immutable feed item selected by the user.
    public func markNotificationFeedItemUnread(_ item: MobileNotificationFeedItem) async {
        await setNotificationFeedItemReadState(item, isRead: false)
    }

    private func setNotificationFeedItemReadState(
        _ item: MobileNotificationFeedItem,
        isRead: Bool
    ) async {
        guard item.isRead != isRead,
              let target = notificationFeedTarget(for: item.macDeviceID) else { return }
        let method = isRead ? "notification.feed.mark_read" : "notification.feed.mark_unread"
        do {
            let request = try MobileCoreRPCClient.requestData(
                method: method,
                params: ["notification_ids": [item.notificationID]]
            )
            let data = try await target.client.sendRequest(request)
            let response = try MobileNotificationFeedMutationResponse.decode(data)
            guard notificationFeedClient(for: item.macDeviceID) === target.client else { return }
            applyNotificationFeedReadStateMutation(
                macDeviceID: item.macDeviceID,
                notificationIDs: [item.notificationID],
                isRead: isRead,
                revision: response.revision
            )
            _ = scheduleNotificationFeedRefresh(
                macDeviceID: item.macDeviceID,
                client: target.client,
                displayName: target.displayName
            )
        } catch {
            notificationFeedLog.error(
                """
                read-state mutation failed \
                method=\(method, privacy: .public) \
                mac=\(item.macDeviceID, privacy: .public) \
                error=\(String(describing: error), privacy: .private)
                """
            )
        }
    }

    /// Marks every retained notification read on each currently connected capable Mac.
    public func markAllNotificationFeedItemsRead() async {
        await markNotificationFeedItemsRead(notificationFeedItems)
    }

    /// Marks every retained notification read for the Macs represented by `items`.
    /// This keeps a computer-scoped feed's bulk action within the scope visible to
    /// the user while still using the host's atomic mark-all mutation per Mac.
    public func markNotificationFeedItemsRead(_ items: [MobileNotificationFeedItem]) async {
        let macDeviceIDs = Set(items.lazy.filter { !$0.isRead }.map(\.macDeviceID))
        let targets = notificationFeedTargets().filter { target in
            macDeviceIDs.contains(target.macDeviceID)
                && notificationFeedSnapshotsByMac[target.macDeviceID]?.items.contains(where: { !$0.isRead }) == true
        }
        for target in targets {
            await markAllNotificationFeedItemsRead(on: target)
        }
    }

    /// Starts a cancellable feed-open operation owned by the shell store.
    ///
    /// The operation remains cancellable until it commits navigation. Once navigation
    /// is committed, ownership is released so the accompanying read mutation may
    /// finish even though the feed view disappears.
    public func requestOpenNotificationFeedItem(_ item: MobileNotificationFeedItem) {
        cancelPendingNotificationFeedOpen()
        let token = UUID()
        notificationFeedOpenToken = token
        notificationFeedOpenTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.openNotificationFeedItem(item, operationToken: token)
        }
    }

    /// Cancels a feed open that has not committed navigation yet.
    ///
    /// - Returns: The cancelled task so tests or lifecycle owners can await its exit.
    @discardableResult
    public func cancelPendingNotificationFeedOpen() -> Task<Void, Never>? {
        guard notificationFeedOpenToken != nil else { return nil }
        let task = notificationFeedOpenTask
        notificationFeedOpenToken = nil
        notificationFeedOpenTask = nil
        task?.cancel()
        _ = cancelPendingMacSwitch(restorePreviousOnCancel: true)
        return task
    }

    /// Opens a feed item in its current destination workspace and pane, then marks it read.
    /// - Parameter item: The immutable feed item selected by the user.
    public func openNotificationFeedItem(_ item: MobileNotificationFeedItem) async {
        await openNotificationFeedItem(item, operationToken: nil)
    }

    private func openNotificationFeedItem(
        _ item: MobileNotificationFeedItem,
        operationToken: UUID?
    ) async {
        defer { finishNotificationFeedOpenOperation(operationToken) }
        if item.macDeviceID != normalizedForegroundNotificationFeedMacID() {
            guard await switchToMac(macDeviceID: item.macDeviceID) else { return }
        }
        let capturedWorkspaceID = workspaceID(
            matchingRemoteWorkspaceID: item.remoteWorkspaceID,
            macDeviceID: item.macDeviceID
        )
        let targetWorkspaceID: MobileWorkspacePreview.ID?
        if item.retargetsToLiveSurfaceOwner, let surfaceID = item.remoteSurfaceID {
            targetWorkspaceID = workspaceID(
                containingSurfaceID: surfaceID,
                macDeviceID: item.macDeviceID
            )
        } else {
            targetWorkspaceID = capturedWorkspaceID
        }
        guard let workspaceID = targetWorkspaceID else {
            notificationFeedLog.error(
                "open target unavailable mac=\(item.macDeviceID, privacy: .public) notification=\(item.notificationID, privacy: .public)"
            )
            return
        }
        guard commitNotificationFeedOpenOperation(operationToken) else { return }

        navigateToWorkspaceForDeeplink(workspaceID, origin: .notificationFeed)
        if let surfaceID = item.remoteSurfaceID,
           workspace(workspaceID, containsSurfaceID: surfaceID) {
            selectTerminal(MobileTerminalPreview.ID(rawValue: surfaceID))
        }
        await markNotificationFeedItemRead(item)
    }

    /// Handles a revision-only feed invalidation from one specific Mac.
    func handleNotificationFeedChangedEvent(
        _ event: MobileEventEnvelope,
        macDeviceID: String,
        client: MobileCoreRPCClient,
        displayName: String
    ) {
        guard event.topic == "notification.feed.changed",
              let payload = event.payloadJSON,
              let changed = MobileNotificationFeedChangedEvent.decode(payload),
              notificationFeedClient(for: macDeviceID) === client else { return }
        let appliedRevision = notificationFeedSnapshotsByMac[macDeviceID]?.revision ?? -1
        let knownRevision = notificationFeedKnownRevisionsByMac[macDeviceID] ?? -1
        guard changed.revision > max(appliedRevision, knownRevision) else { return }
        notificationFeedKnownRevisionsByMac[macDeviceID] = changed.revision
        _ = scheduleNotificationFeedRefresh(
            macDeviceID: macDeviceID,
            client: client,
            displayName: displayName
        )
    }

    /// Starts an initial feed fetch after a capable foreground connection is established.
    func scheduleForegroundNotificationFeedRefresh(client: MobileCoreRPCClient) {
        guard let macDeviceID = normalizedForegroundNotificationFeedMacID(),
              supportedHostCapabilities.contains(Self.notificationFeedCapability),
              remoteClient === client else { return }
        if notificationFeedStatus == .idle {
            notificationFeedStatus = .loading
        }
        _ = scheduleNotificationFeedRefresh(
            macDeviceID: macDeviceID,
            client: client,
            displayName: notificationFeedDisplayName(for: macDeviceID)
        )
    }

    /// Starts an initial feed fetch after a capable secondary connection is established.
    func scheduleSecondaryNotificationFeedRefresh(
        macDeviceID: String,
        client: MobileCoreRPCClient,
        displayName: String?
    ) {
        guard secondaryMacSubscriptions[macDeviceID]?.client === client,
              secondaryMacSubscriptions[macDeviceID]?.supportedHostCapabilities.contains(Self.notificationFeedCapability) == true else { return }
        _ = scheduleNotificationFeedRefresh(
            macDeviceID: macDeviceID,
            client: client,
            displayName: normalizedDisplayName(displayName, fallback: macDeviceID)
        )
    }

    /// Cancels all feed work and removes account-scoped notification content.
    func resetNotificationFeed() {
        cancelPendingNotificationFeedOpen()
        for task in notificationFeedRefreshTasksByMac.values {
            task.cancel()
        }
        notificationFeedRefreshTasksByMac = [:]
        notificationFeedRefreshTokensByMac = [:]
        notificationFeedRefreshPendingMacIDs = []
        notificationFeedKnownRevisionsByMac = [:]
        notificationFeedSuccessfulMacIDs = []
        notificationFeedSnapshotsByMac = [:]
        notificationFeedItems = []
        notificationFeedStatus = .idle
    }

    private func commitNotificationFeedOpenOperation(_ token: UUID?) -> Bool {
        guard let token else { return true }
        guard notificationFeedOpenToken == token, !Task.isCancelled else { return false }
        notificationFeedOpenToken = nil
        notificationFeedOpenTask = nil
        return true
    }

    private func finishNotificationFeedOpenOperation(_ token: UUID?) {
        guard let token, notificationFeedOpenToken == token else { return }
        notificationFeedOpenToken = nil
        notificationFeedOpenTask = nil
    }

    /// Removes one forgotten Mac's content and cancels work that could restore it.
    /// - Parameter macDeviceID: The forgotten Mac's stable device id.
    func removeNotificationFeedSnapshot(macDeviceID: String) {
        notificationFeedRefreshTasksByMac[macDeviceID]?.cancel()
        notificationFeedRefreshTasksByMac[macDeviceID] = nil
        notificationFeedRefreshTokensByMac[macDeviceID] = nil
        notificationFeedRefreshPendingMacIDs.remove(macDeviceID)
        notificationFeedKnownRevisionsByMac[macDeviceID] = nil
        notificationFeedSuccessfulMacIDs.remove(macDeviceID)
        notificationFeedSnapshotsByMac[macDeviceID] = nil
        recomputeNotificationFeedItems()
        if notificationFeedItems.isEmpty, notificationFeedStatus == .ready {
            notificationFeedStatus = resolvedNotificationFeedStatus()
        }
    }

    /// Retains only a team-switch-safe foreground snapshot.
    func retainForegroundNotificationFeedSnapshot() {
        guard let foregroundMacDeviceID = normalizedForegroundNotificationFeedMacID() else {
            resetNotificationFeed()
            return
        }
        let removedIDs = notificationFeedSnapshotsByMac.keys.filter { $0 != foregroundMacDeviceID }
        for id in removedIDs {
            removeNotificationFeedSnapshot(macDeviceID: id)
        }
    }

    /// Rebuilds connection-state projections and deterministic cross-Mac ordering.
    func recomputeNotificationFeedItems() {
        let projected = notificationFeedSnapshotsByMac.map { macDeviceID, snapshot in
            let status = notificationFeedConnectionStatus(for: macDeviceID)
            return snapshot.items.map { $0.updating(connectionStatus: status) }
        }
        notificationFeedItems = notificationFeedAggregation.items(from: projected)
    }

    /// Resolves the foreground Mac id for event routing without exposing RPC state to UI.
    func normalizedForegroundNotificationFeedMacIDForEvent() -> String? {
        normalizedForegroundNotificationFeedMacID()
    }

    /// Resolves a foreground Mac label for event-derived snapshots.
    func notificationFeedDisplayNameForForeground(macDeviceID: String) -> String {
        notificationFeedDisplayName(for: macDeviceID)
    }

    /// Resolves a secondary Mac label for event-derived snapshots.
    func notificationFeedDisplayNameForSecondary(
        macDeviceID: String,
        fallback: String?
    ) -> String {
        let stored = notificationFeedDisplayName(for: macDeviceID)
        return stored == macDeviceID
            ? normalizedDisplayName(fallback, fallback: macDeviceID)
            : stored
    }

    /// Applies a decoded snapshot if its revision is not stale.
    ///
    /// Kept internal so package tests can exercise the revision invariant without
    /// constructing a transport. Production callers additionally validate client
    /// identity before reaching this method.
    @discardableResult
    func applyNotificationFeedSnapshot(
        _ response: MobileNotificationFeedListResponse,
        macDeviceID: String,
        displayName: String
    ) -> Bool {
        let currentRevision = notificationFeedSnapshotsByMac[macDeviceID]?.revision ?? -1
        let minimumRevision = notificationFeedKnownRevisionsByMac[macDeviceID] ?? -1
        guard response.revision >= minimumRevision else {
            // An invalidation arrived while this list RPC was in flight. Keep one
            // trailing pass armed so the newer revision cannot be lost when this
            // stale response returns after the event.
            notificationFeedRefreshPendingMacIDs.insert(macDeviceID)
            return false
        }
        guard response.revision >= currentRevision else { return false }

        let status = notificationFeedConnectionStatus(for: macDeviceID)
        let items = response.notifications.compactMap { wire -> MobileNotificationFeedItem? in
            let id = wire.id.trimmingCharacters(in: .whitespacesAndNewlines)
            let workspaceID = wire.workspaceID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, !workspaceID.isEmpty else { return nil }
            return MobileNotificationFeedItem(
                macDeviceID: macDeviceID,
                notificationID: id,
                macDisplayName: displayName,
                remoteWorkspaceID: workspaceID,
                remoteSurfaceID: normalizedOptional(wire.surfaceID),
                title: wire.title,
                subtitle: normalizedOptional(wire.subtitle),
                body: wire.body,
                createdAt: wire.createdAt,
                isRead: wire.isRead,
                retargetsToLiveSurfaceOwner: wire.retargetsToLiveSurfaceOwner,
                workspaceTitle: normalizedOptional(wire.workspaceTitle),
                surfaceTitle: normalizedOptional(wire.surfaceTitle),
                connectionStatus: status
            )
        }
        notificationFeedSnapshotsByMac[macDeviceID] = NotificationFeedMacSnapshot(
            revision: response.revision,
            items: items
        )
        notificationFeedKnownRevisionsByMac[macDeviceID] = response.revision
        notificationFeedSuccessfulMacIDs.insert(macDeviceID)
        recomputeNotificationFeedItems()
        return true
    }

    private func scheduleNotificationFeedRefresh(
        macDeviceID: String,
        client: MobileCoreRPCClient,
        displayName: String
    ) -> Task<Void, Never>? {
        guard notificationFeedClient(for: macDeviceID) === client,
              notificationFeedClientSupportsCapability(macDeviceID: macDeviceID) else { return nil }
        if let task = notificationFeedRefreshTasksByMac[macDeviceID] {
            notificationFeedRefreshPendingMacIDs.insert(macDeviceID)
            return task
        }

        let token = UUID()
        notificationFeedRefreshTokensByMac[macDeviceID] = token
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            repeat {
                self.notificationFeedRefreshPendingMacIDs.remove(macDeviceID)
                await self.fetchNotificationFeed(
                    macDeviceID: macDeviceID,
                    client: client,
                    displayName: displayName
                )
            } while !Task.isCancelled
                && self.notificationFeedClient(for: macDeviceID) === client
                && self.notificationFeedRefreshPendingMacIDs.contains(macDeviceID)
            guard self.notificationFeedRefreshTokensByMac[macDeviceID] == token else { return }
            self.notificationFeedRefreshTasksByMac[macDeviceID] = nil
            self.notificationFeedRefreshTokensByMac[macDeviceID] = nil
            self.notificationFeedRefreshPendingMacIDs.remove(macDeviceID)
            let connectedTargetIDs = Set(self.notificationFeedTargets().map(\.macDeviceID))
            let hasConnectedRefreshInFlight = self.notificationFeedRefreshTasksByMac.keys.contains {
                connectedTargetIDs.contains($0)
            }
            if !hasConnectedRefreshInFlight {
                self.notificationFeedStatus = self.resolvedNotificationFeedStatus()
            }
        }
        notificationFeedRefreshTasksByMac[macDeviceID] = task
        return task
    }

    private func fetchNotificationFeed(
        macDeviceID: String,
        client: MobileCoreRPCClient,
        displayName: String
    ) async {
        do {
            let request = try MobileCoreRPCClient.requestData(
                method: "notification.feed.list",
                params: [:]
            )
            let data = try await client.sendRequest(request)
            let response = try MobileNotificationFeedListResponse.decode(data)
            guard notificationFeedClient(for: macDeviceID) === client else { return }
            _ = applyNotificationFeedSnapshot(
                response,
                macDeviceID: macDeviceID,
                displayName: displayName
            )
        } catch {
            guard notificationFeedClient(for: macDeviceID) === client else { return }
            notificationFeedLog.error(
                "list failed mac=\(macDeviceID, privacy: .public) error=\(String(describing: error), privacy: .private)"
            )
        }
    }

    private func markAllNotificationFeedItemsRead(on target: NotificationFeedClientTarget) async {
        do {
            let request = try MobileCoreRPCClient.requestData(
                method: "notification.feed.mark_all_read",
                params: [:]
            )
            let data = try await target.client.sendRequest(request)
            let response = try MobileNotificationFeedMutationResponse.decode(data)
            guard notificationFeedClient(for: target.macDeviceID) === target.client else { return }
            let ids = notificationFeedSnapshotsByMac[target.macDeviceID]?.items.map(\.notificationID) ?? []
            applyNotificationFeedReadStateMutation(
                macDeviceID: target.macDeviceID,
                notificationIDs: ids,
                isRead: true,
                revision: response.revision
            )
            _ = scheduleNotificationFeedRefresh(
                macDeviceID: target.macDeviceID,
                client: target.client,
                displayName: target.displayName
            )
        } catch {
            notificationFeedLog.error(
                "mark all read failed mac=\(target.macDeviceID, privacy: .public) error=\(String(describing: error), privacy: .private)"
            )
        }
    }

    /// Applies confirmed read-state flags without claiming that a mutation response is a full snapshot.
    ///
    /// A mutation revision can include notifications absent from the retained list, so callers
    /// must schedule a list refresh after this optimistic projection.
    func applyNotificationFeedReadStateMutation(
        macDeviceID: String,
        notificationIDs: [String],
        isRead: Bool,
        revision: Int
    ) {
        guard var snapshot = notificationFeedSnapshotsByMac[macDeviceID],
              revision >= snapshot.revision else { return }
        let ids = Set(notificationIDs)
        snapshot.items = snapshot.items.map { item in
            ids.contains(item.notificationID) ? item.updating(isRead: isRead) : item
        }
        notificationFeedSnapshotsByMac[macDeviceID] = snapshot
        notificationFeedKnownRevisionsByMac[macDeviceID] = max(
            revision,
            notificationFeedKnownRevisionsByMac[macDeviceID] ?? revision
        )
        recomputeNotificationFeedItems()
    }

    private func notificationFeedTargets() -> [NotificationFeedClientTarget] {
        var targets: [NotificationFeedClientTarget] = []
        if let client = remoteClient,
           let macDeviceID = normalizedForegroundNotificationFeedMacID(),
           supportedHostCapabilities.contains(Self.notificationFeedCapability) {
            targets.append(NotificationFeedClientTarget(
                macDeviceID: macDeviceID,
                displayName: notificationFeedDisplayName(for: macDeviceID),
                client: client
            ))
        }
        for (macDeviceID, subscription) in secondaryMacSubscriptions
        where subscription.supportedHostCapabilities.contains(Self.notificationFeedCapability) {
            targets.append(NotificationFeedClientTarget(
                macDeviceID: macDeviceID,
                displayName: notificationFeedDisplayName(for: macDeviceID),
                client: subscription.client
            ))
        }
        return targets
    }

    private func notificationFeedTarget(for macDeviceID: String) -> NotificationFeedClientTarget? {
        guard let client = notificationFeedClient(for: macDeviceID),
              notificationFeedClientSupportsCapability(macDeviceID: macDeviceID) else { return nil }
        return NotificationFeedClientTarget(
            macDeviceID: macDeviceID,
            displayName: notificationFeedDisplayName(for: macDeviceID),
            client: client
        )
    }

    private func notificationFeedClient(for macDeviceID: String) -> MobileCoreRPCClient? {
        if normalizedForegroundNotificationFeedMacID() == macDeviceID {
            return remoteClient
        }
        return secondaryMacSubscriptions[macDeviceID]?.client
    }

    private func notificationFeedClientSupportsCapability(macDeviceID: String) -> Bool {
        if normalizedForegroundNotificationFeedMacID() == macDeviceID {
            return supportedHostCapabilities.contains(Self.notificationFeedCapability)
        }
        return secondaryMacSubscriptions[macDeviceID]?.supportedHostCapabilities.contains(Self.notificationFeedCapability) == true
    }

    private func notificationFeedConnectionStatus(for macDeviceID: String) -> MobileMacConnectionStatus {
        if normalizedForegroundNotificationFeedMacID() == macDeviceID {
            return remoteClient == nil ? .unavailable : macConnectionStatus
        }
        if secondaryMacSubscriptions[macDeviceID] != nil {
            return .connected
        }
        return workspacesByMac[macDeviceID]?.status ?? .unavailable
    }

    private func normalizedForegroundNotificationFeedMacID() -> String? {
        let raw = foregroundMacDeviceID ?? activeTicket?.macDeviceID
        return normalizedOptional(raw)
    }

    private func notificationFeedDisplayName(for macDeviceID: String) -> String {
        let raw: String?
        if normalizedForegroundNotificationFeedMacID() == macDeviceID {
            raw = activeTicket?.macDisplayName ?? connectedHostName
        } else {
            raw = workspacesByMac[macDeviceID]?.displayName
                ?? pairedMacs.first(where: { $0.macDeviceID == macDeviceID })?.displayName
        }
        return normalizedDisplayName(raw, fallback: macDeviceID)
    }

    private func resolvedNotificationFeedStatus() -> MobileNotificationFeedStatus {
        let connectedClientCount = (remoteClient == nil ? 0 : 1) + secondaryMacSubscriptions.count
        guard connectedClientCount > 0 else { return .unavailable }
        let targets = notificationFeedTargets()
        guard !targets.isEmpty else { return .requiresMacUpdate }
        let targetIDs = Set(targets.map(\.macDeviceID))
        if notificationFeedItems.isEmpty,
           notificationFeedSuccessfulMacIDs.isDisjoint(with: targetIDs) {
            return .unavailable
        }
        return targets.count < connectedClientCount ? .requiresMacUpdate : .ready
    }

    private func normalizedDisplayName(_ value: String?, fallback: String) -> String {
        normalizedOptional(value) ?? fallback
    }

    private func normalizedOptional(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
