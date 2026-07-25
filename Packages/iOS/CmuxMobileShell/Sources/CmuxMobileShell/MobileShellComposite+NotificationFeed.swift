import CmuxMobilePairedMac
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
                ownerKey: target.ownerKey,
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

        var connectedMacDeviceIDs = Set(secondaryMacSubscriptions.values.map(\.macDeviceID))
        if remoteClient != nil, let foregroundID = normalizedForegroundNotificationFeedMacID() {
            connectedMacDeviceIDs.insert(foregroundID)
        }
        let capableMacDeviceIDs = Set(notificationFeedTargets().map(\.macDeviceID))
        let hasConnectedMac = !connectedMacDeviceIDs.isDisjoint(with: macDeviceIDs)
        let hasCapableMac = !capableMacDeviceIDs.isDisjoint(with: macDeviceIDs)
        let snapshotDeviceIDs = Set(notificationFeedSnapshotsByMac.keys.map {
            MobilePairedMac.pairingIdentity(from: $0).macDeviceID
        })
        let hasSnapshot = !snapshotDeviceIDs.isDisjoint(with: macDeviceIDs)
        let successfulDeviceIDs = Set(notificationFeedSuccessfulMacIDs.map {
            MobilePairedMac.pairingIdentity(from: $0).macDeviceID
        })
        let hasSuccessfulSnapshot = !successfulDeviceIDs.isDisjoint(with: macDeviceIDs)
        let refreshingDeviceIDs = Set(notificationFeedRefreshTasksByMac.keys.map {
            MobilePairedMac.pairingIdentity(from: $0).macDeviceID
        })
        let isRefreshing = !refreshingDeviceIDs.isDisjoint(with: macDeviceIDs)

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
              let target = notificationFeedTarget(forOwnerKey: notificationFeedOwnerKey(for: item)) else { return }
        let method = isRead ? "notification.feed.mark_read" : "notification.feed.mark_unread"
        do {
            let request = try MobileCoreRPCClient.requestData(
                method: method,
                params: ["notification_ids": [item.notificationID]]
            )
            let data = try await target.client.sendRequest(request)
            let response = try MobileNotificationFeedMutationResponse.decode(data)
            guard notificationFeedClient(forOwnerKey: target.ownerKey) === target.client else { return }
            applyNotificationFeedReadStateMutation(
                ownerKey: target.ownerKey,
                notificationIDs: [item.notificationID],
                isRead: isRead,
                revision: response.revision
            )
            _ = scheduleNotificationFeedRefresh(
                ownerKey: target.ownerKey,
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
                && notificationFeedSnapshotsByMac[target.ownerKey]?.items.contains(where: { !$0.isRead }) == true
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
        // Compare the exact pairing: a sibling build's notification on the
        // foreground DEVICE still needs a switch to that build.
        let isForegroundPairing = item.macDeviceID == normalizedForegroundNotificationFeedMacID()
            && MobileMacInstanceTagAuthority.sameStoredAuthority(
                item.macInstanceTag, activeMacInstanceTag
            )
        if !isForegroundPairing {
            guard await switchToMac(
                macDeviceID: item.macDeviceID,
                instanceTag: item.macInstanceTag
            ) else { return }
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
        ownerKey: String,
        client: MobileCoreRPCClient,
        displayName: String
    ) {
        guard event.topic == "notification.feed.changed",
              let payload = event.payloadJSON,
              let changed = MobileNotificationFeedChangedEvent.decode(payload),
              notificationFeedClient(forOwnerKey: ownerKey) === client else { return }
        let appliedRevision = notificationFeedSnapshotsByMac[ownerKey]?.revision ?? -1
        let knownRevision = notificationFeedKnownRevisionsByMac[ownerKey] ?? -1
        guard changed.revision > max(appliedRevision, knownRevision) else { return }
        notificationFeedKnownRevisionsByMac[ownerKey] = changed.revision
        _ = scheduleNotificationFeedRefresh(
            ownerKey: ownerKey,
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
            ownerKey: macDeviceID,
            client: client,
            displayName: notificationFeedDisplayName(for: macDeviceID)
        )
    }

    /// Starts an initial feed fetch after a capable secondary connection is established.
    /// `ownerKey` is the subscription's pairing id.
    func scheduleSecondaryNotificationFeedRefresh(
        ownerKey: String,
        client: MobileCoreRPCClient,
        displayName: String?
    ) {
        guard let subscription = secondaryMacSubscriptions[ownerKey],
              subscription.client === client,
              subscription.supportedHostCapabilities.contains(Self.notificationFeedCapability) else { return }
        _ = scheduleNotificationFeedRefresh(
            ownerKey: ownerKey,
            client: client,
            displayName: normalizedDisplayName(displayName, fallback: subscription.macDeviceID)
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

    /// Removes one hidden Mac's content and cancels work that could restore it.
    /// - Parameter macDeviceID: The hidden Mac's stable device id.
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
        let projected = notificationFeedSnapshotsByMac.map { ownerKey, snapshot in
            let status = notificationFeedConnectionStatus(forOwnerKey: ownerKey)
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
        ownerKey: String,
        displayName: String
    ) -> Bool {
        let currentRevision = notificationFeedSnapshotsByMac[ownerKey]?.revision ?? -1
        let minimumRevision = notificationFeedKnownRevisionsByMac[ownerKey] ?? -1
        guard response.revision >= minimumRevision else {
            // An invalidation arrived while this list RPC was in flight. Keep one
            // trailing pass armed so the newer revision cannot be lost when this
            // stale response returns after the event.
            notificationFeedRefreshPendingMacIDs.insert(ownerKey)
            return false
        }
        guard response.revision >= currentRevision else { return false }

        let status = notificationFeedConnectionStatus(forOwnerKey: ownerKey)
        // The owner key identifies the exact pairing this snapshot belongs to;
        // the wire items carry no Mac identity of their own. Bare device keys
        // (the foreground) resolve their tag from the live connection.
        let identity = MobilePairedMac.pairingIdentity(from: ownerKey)
        let macDeviceID = identity.macDeviceID
        let instanceTag = identity.instanceTag ?? notificationFeedInstanceTag(forOwnerKey: ownerKey)
        let items = response.notifications.compactMap { wire -> MobileNotificationFeedItem? in
            let id = wire.id.trimmingCharacters(in: .whitespacesAndNewlines)
            let workspaceID = wire.workspaceID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, !workspaceID.isEmpty else { return nil }
            return MobileNotificationFeedItem(
                macDeviceID: macDeviceID,
                macInstanceTag: instanceTag,
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
        notificationFeedSnapshotsByMac[ownerKey] = NotificationFeedMacSnapshot(
            revision: response.revision,
            items: items
        )
        notificationFeedKnownRevisionsByMac[ownerKey] = response.revision
        notificationFeedSuccessfulMacIDs.insert(ownerKey)
        recomputeNotificationFeedItems()
        return true
    }

    private func scheduleNotificationFeedRefresh(
        ownerKey: String,
        client: MobileCoreRPCClient,
        displayName: String
    ) -> Task<Void, Never>? {
        guard notificationFeedClient(forOwnerKey: ownerKey) === client,
              notificationFeedClientSupportsCapability(ownerKey: ownerKey) else { return nil }
        if let task = notificationFeedRefreshTasksByMac[ownerKey] {
            notificationFeedRefreshPendingMacIDs.insert(ownerKey)
            return task
        }

        let token = UUID()
        notificationFeedRefreshTokensByMac[ownerKey] = token
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            repeat {
                self.notificationFeedRefreshPendingMacIDs.remove(ownerKey)
                await self.fetchNotificationFeed(
                    ownerKey: ownerKey,
                    client: client,
                    displayName: displayName
                )
            } while !Task.isCancelled
                && self.notificationFeedClient(forOwnerKey: ownerKey) === client
                && self.notificationFeedRefreshPendingMacIDs.contains(ownerKey)
            guard self.notificationFeedRefreshTokensByMac[ownerKey] == token else { return }
            self.notificationFeedRefreshTasksByMac[ownerKey] = nil
            self.notificationFeedRefreshTokensByMac[ownerKey] = nil
            self.notificationFeedRefreshPendingMacIDs.remove(ownerKey)
            let connectedTargetKeys = Set(self.notificationFeedTargets().map(\.ownerKey))
            let hasConnectedRefreshInFlight = self.notificationFeedRefreshTasksByMac.keys.contains {
                connectedTargetKeys.contains($0)
            }
            if !hasConnectedRefreshInFlight {
                self.notificationFeedStatus = self.resolvedNotificationFeedStatus()
            }
        }
        notificationFeedRefreshTasksByMac[ownerKey] = task
        return task
    }

    private func fetchNotificationFeed(
        ownerKey: String,
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
            guard notificationFeedClient(forOwnerKey: ownerKey) === client else { return }
            _ = applyNotificationFeedSnapshot(
                response,
                ownerKey: ownerKey,
                displayName: displayName
            )
        } catch {
            guard notificationFeedClient(forOwnerKey: ownerKey) === client else { return }
            notificationFeedLog.error(
                "list failed mac=\(ownerKey, privacy: .public) error=\(String(describing: error), privacy: .private)"
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
            guard notificationFeedClient(forOwnerKey: target.ownerKey) === target.client else { return }
            let ids = notificationFeedSnapshotsByMac[target.ownerKey]?.items.map(\.notificationID) ?? []
            applyNotificationFeedReadStateMutation(
                ownerKey: target.ownerKey,
                notificationIDs: ids,
                isRead: true,
                revision: response.revision
            )
            _ = scheduleNotificationFeedRefresh(
                ownerKey: target.ownerKey,
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
        ownerKey: String,
        notificationIDs: [String],
        isRead: Bool,
        revision: Int
    ) {
        guard var snapshot = notificationFeedSnapshotsByMac[ownerKey],
              revision >= snapshot.revision else { return }
        let ids = Set(notificationIDs)
        snapshot.items = snapshot.items.map { item in
            ids.contains(item.notificationID) ? item.updating(isRead: isRead) : item
        }
        notificationFeedSnapshotsByMac[ownerKey] = snapshot
        notificationFeedKnownRevisionsByMac[ownerKey] = max(
            revision,
            notificationFeedKnownRevisionsByMac[ownerKey] ?? revision
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
                instanceTag: activeMacInstanceTag,
                displayName: notificationFeedDisplayName(for: macDeviceID),
                ownerKey: macDeviceID,
                client: client
            ))
        }
        for (ownerKey, subscription) in secondaryMacSubscriptions
        where subscription.supportedHostCapabilities.contains(Self.notificationFeedCapability) {
            targets.append(NotificationFeedClientTarget(
                macDeviceID: subscription.macDeviceID,
                instanceTag: subscription.authenticatedInstanceTag ?? subscription.storedInstanceTag,
                displayName: notificationFeedDisplayName(for: subscription.macDeviceID),
                ownerKey: ownerKey,
                client: subscription.client
            ))
        }
        return targets
    }

    private func notificationFeedTarget(forOwnerKey ownerKey: String) -> NotificationFeedClientTarget? {
        guard let client = notificationFeedClient(forOwnerKey: ownerKey),
              notificationFeedClientSupportsCapability(ownerKey: ownerKey) else { return nil }
        let macDeviceID = MobilePairedMac.pairingIdentity(from: ownerKey).macDeviceID
        return NotificationFeedClientTarget(
            macDeviceID: macDeviceID,
            instanceTag: notificationFeedInstanceTag(forOwnerKey: ownerKey),
            displayName: notificationFeedDisplayName(for: macDeviceID),
            ownerKey: ownerKey,
            client: client
        )
    }

    /// The pairing tag behind a feed target: the foreground connection's tag,
    /// or the secondary subscription's proven tag.
    /// `ownerKey` is the feed-map key: the foreground's normalized device id,
    /// or a secondary subscription's pairing id.
    private func notificationFeedInstanceTag(forOwnerKey ownerKey: String) -> String? {
        if normalizedForegroundNotificationFeedMacID() == ownerKey {
            return activeMacInstanceTag
        }
        let subscription = secondaryMacSubscriptions[ownerKey]
        return subscription?.authenticatedInstanceTag ?? subscription?.storedInstanceTag
    }

    private func notificationFeedClient(forOwnerKey ownerKey: String) -> MobileCoreRPCClient? {
        if normalizedForegroundNotificationFeedMacID() == ownerKey {
            return remoteClient
        }
        return secondaryMacSubscriptions[ownerKey]?.client
    }

    private func notificationFeedClientSupportsCapability(ownerKey: String) -> Bool {
        if normalizedForegroundNotificationFeedMacID() == ownerKey {
            return supportedHostCapabilities.contains(Self.notificationFeedCapability)
        }
        return secondaryMacSubscriptions[ownerKey]?.supportedHostCapabilities.contains(Self.notificationFeedCapability) == true
    }

    private func notificationFeedConnectionStatus(forOwnerKey ownerKey: String) -> MobileMacConnectionStatus {
        if normalizedForegroundNotificationFeedMacID() == ownerKey {
            return remoteClient == nil ? .unavailable : macConnectionStatus
        }
        if secondaryMacSubscriptions[ownerKey] != nil {
            return .connected
        }
        return workspacesByMac[ownerKey]?.status ?? .unavailable
    }

    /// The feed-map key that owns `item`: the foreground key when the item is
    /// the foreground pairing's, else the owning secondary's pairing id, else
    /// the item's device id (legacy rows).
    private func notificationFeedOwnerKey(for item: MobileNotificationFeedItem) -> String {
        if let foreground = normalizedForegroundNotificationFeedMacID(),
           foreground == item.macDeviceID,
           MobileMacInstanceTagAuthority.sameStoredAuthority(
               item.macInstanceTag, activeMacInstanceTag
           ) {
            return foreground
        }
        let pairingKey = MobilePairedMac.pairingID(
            macDeviceID: item.macDeviceID, instanceTag: item.macInstanceTag
        )
        if secondaryMacSubscriptions[pairingKey] != nil { return pairingKey }
        return item.macDeviceID
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
        let targetOwnerKeys = Set(targets.map(\.ownerKey))
        if notificationFeedItems.isEmpty,
           notificationFeedSuccessfulMacIDs.isDisjoint(with: targetOwnerKeys) {
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
