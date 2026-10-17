import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileRPC
public import CmuxMobileShellModel
import Foundation
internal import OSLog

private let notificationFeedLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "dev.cmux.ios",
    category: "notification-feed"
)

nonisolated private let mobileShellNotificationFeedIdentifierByteLimit = 512
nonisolated private let mobileShellNotificationFeedTitleByteLimit = 512
nonisolated private let mobileShellNotificationFeedSubtitleByteLimit = 512
nonisolated private let mobileShellNotificationFeedBodyByteLimit = 2_048
nonisolated private let mobileShellNotificationFeedMetadataByteLimit = 512
nonisolated private let mobileShellNotificationFeedMaximumImmediateRefreshAttempts = 2

@MainActor
extension MobileShellComposite {
    /// Refreshes the chronological feed from every currently connected capable Mac.
    ///
    /// A Mac that is offline keeps its last-known snapshot. Connected Macs that
    /// predate `notification.feed.v1` are excluded without hiding snapshots from
    /// newer or temporarily unavailable Macs.
    public func refreshNotificationFeed() async {
        let startedAt = appDiagnosticNow()
        recordAppEvent(.notificationFeedLoadStarted)
        let targets = notificationFeedTargets()
        if targets.isEmpty {
            recomputeNotificationFeedItems()
            notificationFeedStatus = resolvedNotificationFeedStatus()
            recordAppEvent(
                .notificationFeedLoadFailed,
                startedAt: startedAt,
                failure: .endpointUnavailable
            )
            return
        }

        notificationFeedStatus = .loading
        let tasks = targets.compactMap { target in
            scheduleNotificationFeedRefresh(
                macDeviceID: target.ownerKey,
                client: target.client,
                displayName: target.displayName
            )
        }
        var outcomes: [NotificationFeedFetchOutcome] = []
        for task in tasks {
            outcomes.append(await task.value)
        }
        recomputeNotificationFeedItems()
        notificationFeedStatus = resolvedNotificationFeedStatus()
        if outcomes.contains(.applied) {
            recordAppEvent(
                .notificationFeedLoadSucceeded,
                startedAt: startedAt,
                count: notificationFeedItems.count
            )
        } else {
            recordAppEvent(
                .notificationFeedLoadFailed,
                startedAt: startedAt,
                failure: Task.isCancelled
                    ? .cancelled
                    : (outcomes.contains(.failed) ? .endpointUnavailable : .superseded)
            )
        }
    }

    /// Resolves feed availability for one computer picker scope. A retained
    /// snapshot stays visible while its Mac is offline, while a connected Mac
    /// without the feed capability reports that it needs an update.
    public func notificationFeedStatus(
        scopedTo macDeviceIDs: Set<String>?
    ) -> MobileNotificationFeedStatus {
        guard let scopeEntries = macDeviceIDs, !scopeEntries.isEmpty else {
            return notificationFeedStatus
        }
        // Entries are bare device ids or pairing ids. Every availability signal
        // matches the exact pairing so a build-scoped selection never reads
        // ready/connected off its sibling.
        let parsedScopeEntries =
            MobileWorkspaceListFilter.parsedMachineEntries(scopeEntries)
        func matches(deviceID: String, tag: String?) -> Bool {
            parsedScopeEntries.contains {
                $0.matches(deviceID: deviceID, rowTag: tag)
            }
        }
        func ownerKeyMatches(_ ownerKey: String) -> Bool {
            let identity = MobilePairedMac.pairingIdentity(from: ownerKey)
            return matches(
                deviceID: identity.macDeviceID,
                tag: identity.instanceTag ?? notificationFeedInstanceTag(forOwnerKey: ownerKey)
            )
        }
        var hasConnectedMac = secondaryMacSubscriptions.contains { _, subscription in
            matches(deviceID: subscription.macDeviceID, tag: subscription.storedInstanceTag)
        }
        if !hasConnectedMac, remoteClient != nil,
           let foregroundID = normalizedForegroundNotificationFeedMacID(),
           matches(deviceID: foregroundID, tag: activeMacInstanceTag) {
            hasConnectedMac = true
        }
        let hasCapableMac = notificationFeedTargets().contains {
            matches(deviceID: $0.macDeviceID, tag: $0.instanceTag)
        }
        let hasSnapshot = notificationFeedSnapshotsByMac.keys.contains(where: ownerKeyMatches)
        let hasSuccessfulSnapshot = notificationFeedSuccessfulMacIDs.contains(where: ownerKeyMatches)
        let isRefreshing = notificationFeedRefreshTasksByMac.keys.contains(where: ownerKeyMatches)

        // A scope covering the demonstration computer is served entirely from
        // its seeded snapshot; it has no RPC client to count as "connected".
        if demonstrationNotificationFeedSeeded,
           let session = demoContentSession,
           matches(deviceID: session.pairingKey.canonicalMacDeviceID, tag: nil) {
            return .ready
        }

        guard hasConnectedMac else { return .unavailable }
        guard hasCapableMac else { return .requiresMacUpdate }
        if isRefreshing, !hasSnapshot, !hasSuccessfulSnapshot { return .loading }
        if hasSnapshot || hasSuccessfulSnapshot { return .ready }
        return .unavailable
    }

    /// Builds a computer-picker-scoped feed from the retained source snapshots
    /// before applying the global row cap. Rows whose current navigation target
    /// is absent from the live workspace snapshot stay retained but are not
    /// presented. Filtering the already-capped global feed can hide valid older
    /// rows when newer retained rows are no longer navigable.
    public func notificationFeedItems(
        scopedTo macDeviceIDs: Set<String>?
    ) -> [MobileNotificationFeedItem] {
        // Scope entries are bare device ids or pairing ids. Matching happens
        // per ITEM (each carries its stamped tag) so a build-scoped selection
        // excludes the sibling's rows even inside the foreground's
        // device-keyed snapshot.
        let parsedScopeEntries = macDeviceIDs.flatMap { ids in
            ids.isEmpty ? nil : MobileWorkspaceListFilter.parsedMachineEntries(ids)
        }
        let targetIndex = NotificationFeedWorkspaceTargetIndex(workspaces: workspaces)
        let projected = notificationFeedSnapshotsByMac.compactMap {
            entry -> MobileNotificationFeedSourceSnapshot? in
            let ownerKey = entry.key
            let items = entry.value.items.filter { item in
                guard targetIndex.workspaceID(for: item) != nil else {
                    return false
                }
                guard let parsedScopeEntries else { return true }
                return parsedScopeEntries.contains {
                    $0.matches(deviceID: item.macDeviceID, rowTag: item.macInstanceTag)
                }
            }
            guard !items.isEmpty else { return nil }
            return MobileNotificationFeedSourceSnapshot(
                items: items,
                connectionStatus: notificationFeedConnectionStatus(for: ownerKey)
            )
        }
        return notificationFeedAggregation.items(from: projected)
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
        if applyDemonstrationNotificationReadState(item, isRead: isRead) {
            recordAppEvent(
                .notificationFeedItemMarkedRead,
                correlationID: item.notificationID,
                count: isRead ? 1 : 0
            )
            return
        }
        guard item.isRead != isRead,
              let target = notificationFeedTarget(for: notificationFeedOwnerKey(for: item)) else {
            recordAppEvent(
                .notificationFeedItemMarkedRead,
                correlationID: item.notificationID,
                failure: .endpointUnavailable,
                count: isRead ? 1 : 0
            )
            return
        }
        let method = isRead ? "notification.feed.mark_read" : "notification.feed.mark_unread"
        do {
            let request = try MobileCoreRPCClient.requestData(
                method: method,
                params: ["notification_ids": [item.notificationID]]
            )
            let data = try await target.client.sendRequest(request)
            let response = try MobileNotificationFeedMutationResponse.decode(data)
            guard notificationFeedClient(for: target.ownerKey) === target.client else { return }
            applyNotificationFeedReadStateMutation(
                macDeviceID: target.ownerKey,
                notificationIDs: [item.notificationID],
                isRead: isRead,
                revision: response.revision
            )
            _ = scheduleNotificationFeedRefresh(
                macDeviceID: target.ownerKey,
                client: target.client,
                displayName: target.displayName
            )
            recordAppEvent(
                .notificationFeedItemMarkedRead,
                correlationID: item.notificationID,
                count: isRead ? 1 : 0
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
            recordAppEvent(
                .notificationFeedItemMarkedRead,
                correlationID: item.notificationID,
                failure: DiagnosticFailureKind.classify(error),
                count: isRead ? 1 : 0
            )
        }
    }

    /// Marks every retained notification read on each currently connected capable Mac.
    public func markAllNotificationFeedItemsRead() async {
        await markNotificationFeedItemsRead(scopedTo: nil)
    }

    /// Marks every retained notification read for the selected computer scope.
    /// This keeps a computer-scoped feed's bulk action within the scope visible to
    /// the user without deriving mutation targets from the capped visible rows.
    public func markNotificationFeedItemsRead(scopedTo macDeviceIDs: Set<String>?) async {
        if macDeviceIDs?.isEmpty == true { return }
        markDemonstrationNotificationFeedItemsRead(scopedTo: macDeviceIDs)
        let parsedScopeEntries = macDeviceIDs.map(
            MobileWorkspaceListFilter.parsedMachineEntries
        )
        let targets = notificationFeedTargets().filter { target in
            (parsedScopeEntries?.contains(where: {
                $0.matches(deviceID: target.macDeviceID, rowTag: target.instanceTag)
            }) ?? true)
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
        recordAppEvent(
            .notificationFeedItemOpened,
            correlationID: item.notificationID,
            count: 0
        )
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
        let isForegroundPairing = normalizedForegroundNotificationFeedMacID().map {
            MacPairingKey(
                macDeviceID: item.macDeviceID,
                instanceTag: item.macInstanceTag
            ) == MacPairingKey(
                macDeviceID: $0,
                instanceTag: activeMacInstanceTag
            )
        } ?? false
        if !isForegroundPairing {
            guard await switchToMac(
                macDeviceID: item.macDeviceID,
                instanceTag: item.macInstanceTag
            ) else {
                recordAppEvent(
                    .notificationFeedItemOpened,
                    correlationID: item.notificationID,
                    failure: .connectionClosed,
                    count: 0
                )
                return
            }
        }
        guard let workspaceID = notificationFeedTargetWorkspaceID(for: item) else {
            notificationFeedLog.error(
                "open target unavailable mac=\(item.macDeviceID, privacy: .public) notification=\(item.notificationID, privacy: .public)"
            )
            recordAppEvent(
                .notificationFeedItemOpened,
                correlationID: item.notificationID,
                failure: .endpointUnavailable,
                count: 0
            )
            return
        }
        guard commitNotificationFeedOpenOperation(operationToken) else {
            recordAppEvent(
                .notificationFeedItemOpened,
                correlationID: item.notificationID,
                failure: .cancelled,
                count: 0
            )
            return
        }

        navigateToWorkspaceForDeeplink(workspaceID, origin: .notificationFeed)
        if let surfaceID = item.remoteSurfaceID,
           workspace(workspaceID, containsSurfaceID: surfaceID) {
            selectTerminal(MobileTerminalPreview.ID(rawValue: surfaceID))
        }
        recordAppEvent(
            .notificationFeedItemOpened,
            correlationID: item.notificationID,
            count: 1
        )
        await markNotificationFeedItemRead(item)
    }

    /// Resolves the same live destination used by feed visibility and opening.
    /// Sibling builds share Mac-local ids, so every lookup includes the item's
    /// exact pairing identity.
    private func notificationFeedTargetWorkspaceID(
        for item: MobileNotificationFeedItem
    ) -> MobileWorkspacePreview.ID? {
        NotificationFeedWorkspaceTargetIndex(workspaces: workspaces)
            .workspaceID(for: item)
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
        guard let macDeviceID = normalizedForegroundNotificationFeedOwnerKey(),
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
        let ownerKey = MacPairingKey(pairingID: macDeviceID)
        guard secondaryMacSubscriptions[ownerKey]?.client === client,
              client !== remoteClient,
              secondaryMacSubscriptions[ownerKey]?.supportedHostCapabilities.contains(Self.notificationFeedCapability) == true else { return }
        _ = scheduleNotificationFeedRefresh(
            macDeviceID: macDeviceID,
            client: client,
            displayName: normalizedDisplayName(displayName, fallback: macDeviceID)
        )
    }

    /// Await the notification half of a control-stream missed-window repair.
    /// Hosts without the feed capability have nothing to reconcile.
    func reconcileSecondaryNotificationFeedAfterControlGap(
        macDeviceID: String,
        client: MobileCoreRPCClient,
        displayName: String?
    ) async -> Bool {
        let reconcileOwnerKey = MacPairingKey(pairingID: macDeviceID)
        guard let subscription = secondaryMacSubscriptions[reconcileOwnerKey],
              subscription.client === client,
              !subscription.isTransitioningToFocus else {
            return false
        }
        if client === remoteClient { return true }
        guard subscription.supportedHostCapabilities.contains(
            Self.notificationFeedCapability
        ) else {
            return true
        }
        let outcome = await fetchNotificationFeed(
            macDeviceID: macDeviceID,
            client: client,
            displayName: normalizedDisplayName(
                displayName,
                fallback: macDeviceID
            )
        )
        switch outcome {
        case .applied:
            return secondaryMacSubscriptions[reconcileOwnerKey] === subscription
                && !subscription.isTransitioningToFocus
        case .failed:
            return false
        case .stale:
            // Capture the missed-window floor and await exactly one trailing
            // list request. Invalidation churn after this point remains owned
            // by the detached coalescer instead of extending activation.
            let requiredRevision =
                notificationFeedKnownRevisionsByMac[macDeviceID] ?? -1
            let trailingOutcome = await fetchNotificationFeed(
                macDeviceID: macDeviceID,
                client: client,
                displayName: normalizedDisplayName(
                    displayName,
                    fallback: macDeviceID
                ),
                requiredRevision: requiredRevision
            )
            guard case .applied = trailingOutcome else {
                return false
            }
            let appliedRevision =
                notificationFeedSnapshotsByMac[macDeviceID]?.revision ?? -1
            let knownRevision =
                notificationFeedKnownRevisionsByMac[macDeviceID] ?? -1
            if appliedRevision < knownRevision {
                _ = scheduleNotificationFeedRefresh(
                    macDeviceID: macDeviceID,
                    client: client,
                    displayName: normalizedDisplayName(
                        displayName,
                        fallback: macDeviceID
                    )
                )
            }
            return secondaryMacSubscriptions[reconcileOwnerKey] === subscription
                && !subscription.isTransitioningToFocus
        }
    }

    /// Cancels all feed work and removes account-scoped notification content.
    func resetNotificationFeed() {
        cancelPendingNotificationFeedOpen()
        for task in notificationFeedRefreshTasksByMac.values {
            task.cancel()
        }
        for task in notificationFeedRefreshRetryTasksByMac.values {
            task.cancel()
        }
        notificationFeedRefreshTasksByMac = [:]
        notificationFeedRefreshTokensByMac = [:]
        notificationFeedRefreshPendingMacIDs = []
        notificationFeedRefreshRetryTasksByMac = [:]
        notificationFeedRefreshRetryTokensByMac = [:]
        notificationFeedRefreshGenerationByMac = [:]
        notificationFeedRefreshRetryConsumedGenerationByMac = [:]
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

    /// Clears the bare-device-key feed bookkeeping when the foreground pairing
    /// changes to a SIBLING build: the old build's snapshot/revision under the
    /// shared device key would reject the new build's (lower) revisions as
    /// stale and keep the old build's rows on screen.
    func resetForegroundNotificationFeedIfInstanceChanged(
        previousDeviceID: String?,
        previousTag: String?,
        newDeviceID: String?,
        newTag: String?
    ) {
        guard let newDeviceID, !newDeviceID.isEmpty,
              previousDeviceID == newDeviceID,
              !macInstanceTagAuthority.sameStoredAuthority(previousTag, newTag) else {
            return
        }
        let pairingID = MobilePairedMac.pairingID(
            macDeviceID: newDeviceID,
            instanceTag: newTag
        )
        removeNotificationFeedSnapshot(macDeviceID: pairingID)
    }

    /// Removes one hidden Mac's content and cancels work that could restore it.
    /// - Parameter macDeviceID: The hidden Mac's stable device id.
    func removeNotificationFeedSnapshot(macDeviceID: String) {
        notificationFeedRefreshTasksByMac[macDeviceID]?.cancel()
        notificationFeedRefreshRetryTasksByMac[macDeviceID]?.cancel()
        notificationFeedRefreshTasksByMac[macDeviceID] = nil
        notificationFeedRefreshTokensByMac[macDeviceID] = nil
        notificationFeedRefreshPendingMacIDs.remove(macDeviceID)
        notificationFeedRefreshRetryTasksByMac[macDeviceID] = nil
        notificationFeedRefreshRetryTokensByMac[macDeviceID] = nil
        notificationFeedRefreshGenerationByMac[macDeviceID] = nil
        notificationFeedRefreshRetryConsumedGenerationByMac[macDeviceID] = nil
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
        guard let foregroundMacDeviceID = normalizedForegroundNotificationFeedOwnerKey() else {
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
            return MobileNotificationFeedSourceSnapshot(
                items: snapshot.items,
                connectionStatus: status
            )
        }
        notificationFeedItems = notificationFeedAggregation.items(from: projected)
    }

    /// Keeps the first row for each identity. Callers provide newest-first
    /// items, so the retained row is the row aggregation would emit.
    private func deduplicatedNotificationFeedItems(
        _ items: [MobileNotificationFeedItem]
    ) -> [MobileNotificationFeedItem] {
        var seenIDs = Set<MobileNotificationFeedItemID>()
        seenIDs.reserveCapacity(items.count)
        var uniqueItems: [MobileNotificationFeedItem] = []
        uniqueItems.reserveCapacity(items.count)
        for item in items {
            guard seenIDs.insert(item.id).inserted else { continue }
            uniqueItems.append(item)
        }
        return uniqueItems
    }

    /// Resolves the foreground Mac id for event routing without exposing RPC state to UI.
    func normalizedForegroundNotificationFeedMacIDForEvent() -> String? {
        normalizedForegroundNotificationFeedOwnerKey()
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
        displayName: String,
        requiredRevision: Int? = nil
    ) -> Bool {
        guard let macDeviceID = normalizedIdentifier(macDeviceID) else { return false }
        let currentRevision = notificationFeedSnapshotsByMac[macDeviceID]?.revision ?? -1
        let knownRevision =
            notificationFeedKnownRevisionsByMac[macDeviceID] ?? -1
        let minimumRevision = requiredRevision ?? knownRevision
        guard response.revision >= minimumRevision else {
            // An invalidation arrived while this list RPC was in flight. Keep one
            // trailing pass armed so the newer revision cannot be lost when this
            // stale response returns after the event.
            notificationFeedRefreshPendingMacIDs.insert(macDeviceID)
            return false
        }
        if response.revision < currentRevision {
            if currentRevision < knownRevision {
                notificationFeedRefreshPendingMacIDs.insert(macDeviceID)
            }
            return currentRevision >= minimumRevision
        }

        let status = notificationFeedConnectionStatus(for: macDeviceID)
        // The key identifies the exact pairing this snapshot belongs to; the
        // wire items carry no Mac identity of their own. Bare device keys
        // (the foreground) resolve their tag from the live connection.
        let identity = MobilePairedMac.pairingIdentity(from: macDeviceID)
        let itemMacDeviceID = identity.macDeviceID
        let itemInstanceTag = identity.instanceTag
            ?? notificationFeedInstanceTag(forOwnerKey: macDeviceID)
        let macDisplayName = normalizedDisplayName(displayName, fallback: itemMacDeviceID)
        // The Mac feed contract is newest-first. Cap each source snapshot
        // before local projection, then sort only that bounded window. Do not
        // destructively prune source tails by the current global top rows:
        // aggregation is already lazy-capped, and retained per-Mac tails are
        // needed to refill the feed when another source is removed or shrinks.
        let items = deduplicatedNotificationFeedItems(
            response.notifications
                .prefix(MobileNotificationFeedAggregation.maxItemCount)
                .compactMap { wire -> MobileNotificationFeedItem? in
                    guard let id = normalizedIdentifier(wire.id),
                          let workspaceID = normalizedIdentifier(wire.workspaceID) else {
                        return nil
                    }
                    return MobileNotificationFeedItem(
                        macDeviceID: itemMacDeviceID,
                        macInstanceTag: itemInstanceTag,
                        notificationID: id,
                        macDisplayName: macDisplayName,
                        remoteWorkspaceID: workspaceID,
                        remoteSurfaceID: normalizedOptionalIdentifier(wire.surfaceID),
                        title: mobileShellNotificationFeedString(
                            wire.title,
                            limitedToUTF8Bytes: mobileShellNotificationFeedTitleByteLimit
                        ),
                        subtitle: normalizedOptionalText(
                            wire.subtitle,
                            limitedToUTF8Bytes: mobileShellNotificationFeedSubtitleByteLimit
                        ),
                        body: mobileShellNotificationFeedString(
                            wire.body,
                            limitedToUTF8Bytes: mobileShellNotificationFeedBodyByteLimit
                        ),
                        createdAt: wire.createdAt,
                        isRead: wire.isRead,
                        retargetsToLiveSurfaceOwner: wire.retargetsToLiveSurfaceOwner,
                        workspaceTitle: normalizedOptionalText(
                            wire.workspaceTitle,
                            limitedToUTF8Bytes: mobileShellNotificationFeedMetadataByteLimit
                        ),
                        surfaceTitle: normalizedOptionalText(
                            wire.surfaceTitle,
                            limitedToUTF8Bytes: mobileShellNotificationFeedMetadataByteLimit
                        ),
                        connectionStatus: status
                    )
                }
                .sorted { lhs, rhs in
                    if lhs.createdAt != rhs.createdAt {
                        return lhs.createdAt > rhs.createdAt
                    }
                    return lhs.id < rhs.id
                }
        )
        notificationFeedSnapshotsByMac[macDeviceID] = NotificationFeedMacSnapshot(
            revision: response.revision,
            items: items
        )
        notificationFeedKnownRevisionsByMac[macDeviceID] = max(
            knownRevision,
            response.revision
        )
        if response.revision < knownRevision {
            notificationFeedRefreshPendingMacIDs.insert(macDeviceID)
        }
        notificationFeedSuccessfulMacIDs.insert(macDeviceID)
        recomputeNotificationFeedItems()
        return true
    }

    private func scheduleNotificationFeedRefresh(
        macDeviceID: String,
        client: MobileCoreRPCClient,
        displayName: String,
        advancesGeneration: Bool = true
    ) -> Task<NotificationFeedFetchOutcome, Never>? {
        guard notificationFeedClient(for: macDeviceID) === client,
              notificationFeedClientSupportsCapability(macDeviceID: macDeviceID) else { return nil }
        if advancesGeneration {
            notificationFeedRefreshGenerationByMac[macDeviceID, default: 0]
                &+= 1
            if let retry =
                notificationFeedRefreshRetryTasksByMac[macDeviceID] {
                notificationFeedRefreshPendingMacIDs.insert(macDeviceID)
                return retry
            }
        }
        if let task = notificationFeedRefreshTasksByMac[macDeviceID] {
            notificationFeedRefreshPendingMacIDs.insert(macDeviceID)
            return task
        }

        let token = UUID()
        notificationFeedRefreshTokensByMac[macDeviceID] = token
        let task = Task { @MainActor [weak self] in
            guard let self else { return NotificationFeedFetchOutcome.failed }
            var attemptCount = 0
            var aggregateOutcome = NotificationFeedFetchOutcome.failed
            repeat {
                self.notificationFeedRefreshPendingMacIDs.remove(macDeviceID)
                let requiredRevision =
                    self.notificationFeedKnownRevisionsByMac[macDeviceID] ?? -1
                let outcome = await self.fetchNotificationFeed(
                    macDeviceID: macDeviceID,
                    client: client,
                    displayName: displayName,
                    requiredRevision: requiredRevision
                )
                if outcome == .applied || aggregateOutcome != .applied {
                    aggregateOutcome = outcome
                }
                attemptCount += 1
            } while attemptCount
                < mobileShellNotificationFeedMaximumImmediateRefreshAttempts
                && !Task.isCancelled
                && self.notificationFeedClient(for: macDeviceID) === client
                && self.notificationFeedRefreshPendingMacIDs.contains(macDeviceID)
            guard self.notificationFeedRefreshTokensByMac[macDeviceID] == token else {
                return .stale
            }
            let stillPending =
                self.notificationFeedRefreshPendingMacIDs.contains(macDeviceID)
            self.notificationFeedRefreshTasksByMac[macDeviceID] = nil
            self.notificationFeedRefreshTokensByMac[macDeviceID] = nil
            if stillPending,
               !Task.isCancelled,
               self.notificationFeedClient(for: macDeviceID) === client {
                self.scheduleDelayedNotificationFeedRefresh(
                    macDeviceID: macDeviceID,
                    client: client,
                    displayName: displayName
                )
            } else {
                self.notificationFeedRefreshPendingMacIDs.remove(macDeviceID)
            }
            let connectedTargetIDs = Set(self.notificationFeedTargets().map(\.ownerKey))
            let hasConnectedRefreshInFlight = self.notificationFeedRefreshTasksByMac.keys.contains {
                connectedTargetIDs.contains($0)
            }
            if !hasConnectedRefreshInFlight {
                self.notificationFeedStatus = self.resolvedNotificationFeedStatus()
            }
            return aggregateOutcome
        }
        notificationFeedRefreshTasksByMac[macDeviceID] = task
        return task
    }

    private func scheduleDelayedNotificationFeedRefresh(
        macDeviceID: String,
        client: MobileCoreRPCClient,
        displayName: String
    ) {
        let scheduledGeneration =
            notificationFeedRefreshGenerationByMac[macDeviceID] ?? 0
        guard notificationFeedRefreshRetryConsumedGenerationByMac[macDeviceID]
                != scheduledGeneration,
              notificationFeedRefreshRetryTasksByMac[macDeviceID] == nil else {
            return
        }
        notificationFeedRefreshRetryConsumedGenerationByMac[macDeviceID] =
            scheduledGeneration
        let token = UUID()
        notificationFeedRefreshRetryTokensByMac[macDeviceID] = token
        let clock = controlPlaneSchedulingClock
        notificationFeedRefreshRetryTasksByMac[macDeviceID] = Task {
            @MainActor [weak self] in
            guard let self else { return .failed }
            defer {
                if self.notificationFeedRefreshRetryTokensByMac[macDeviceID]
                    == token {
                    self.notificationFeedRefreshRetryTasksByMac[macDeviceID] =
                        nil
                    self.notificationFeedRefreshRetryTokensByMac[macDeviceID] =
                        nil
                }
            }
            do {
                try await clock.sleep(for: .seconds(1))
            } catch {
                return .stale
            }
            guard !Task.isCancelled,
                  self.notificationFeedRefreshRetryTokensByMac[macDeviceID]
                    == token,
                  self.notificationFeedClient(for: macDeviceID) === client else {
                return .stale
            }
            let servicedGeneration =
                self.notificationFeedRefreshGenerationByMac[macDeviceID] ?? 0
            self.notificationFeedRefreshRetryConsumedGenerationByMac[
                macDeviceID
            ] = servicedGeneration
            let refresh = self.scheduleNotificationFeedRefresh(
                macDeviceID: macDeviceID,
                client: client,
                displayName: displayName,
                advancesGeneration: false
            )
            let outcome = await refresh?.value ?? .failed
            guard self.notificationFeedRefreshRetryTokensByMac[macDeviceID]
                    == token else {
                return outcome
            }
            self.notificationFeedRefreshRetryTasksByMac[macDeviceID] = nil
            self.notificationFeedRefreshRetryTokensByMac[macDeviceID] = nil
            if self.notificationFeedRefreshPendingMacIDs.contains(
                macDeviceID
            ) {
                self.scheduleDelayedNotificationFeedRefresh(
                    macDeviceID: macDeviceID,
                    client: client,
                    displayName: displayName
                )
            }
            return outcome
        }
    }

    private func fetchNotificationFeed(
        macDeviceID: String,
        client: MobileCoreRPCClient,
        displayName: String,
        requiredRevision: Int? = nil
    ) async -> NotificationFeedFetchOutcome {
        let startedAt = appDiagnosticNow()
        recordAppEvent(.notificationFeedLoadStarted, correlationID: macDeviceID)
        do {
            let request = try MobileCoreRPCClient.requestData(
                method: "notification.feed.list",
                params: [:]
            )
            let data = try await client.sendRequest(request)
            let stringLimits = mobileShellNotificationFeedListStringLimits()
            let maxNotifications = MobileNotificationFeedAggregation.maxItemCount
            let decoderTask = Task.detached(priority: .userInitiated) {
                try MobileNotificationFeedListResponse(
                    decodingBounded: data,
                    maxNotifications: maxNotifications,
                    stringLimits: stringLimits
                )
            }
            let response = try await withTaskCancellationHandler(
                operation: { try await decoderTask.value },
                onCancel: { decoderTask.cancel() }
            )
            guard !Task.isCancelled else {
                recordAppEvent(
                    .notificationFeedLoadFailed,
                    correlationID: macDeviceID,
                    startedAt: startedAt,
                    failure: .cancelled
                )
                return .failed
            }
            guard notificationFeedClient(for: macDeviceID) === client else {
                recordAppEvent(
                    .notificationFeedLoadFailed,
                    correlationID: macDeviceID,
                    startedAt: startedAt,
                    failure: .superseded
                )
                return .failed
            }
            let applied = applyNotificationFeedSnapshot(
                response,
                macDeviceID: macDeviceID,
                displayName: displayName,
                requiredRevision: requiredRevision
            )
            recordAppEvent(
                applied ? .notificationFeedLoadSucceeded : .notificationFeedLoadFailed,
                correlationID: macDeviceID,
                startedAt: startedAt,
                failure: applied ? nil : .superseded,
                count: applied ? response.notifications.count : nil
            )
            return applied ? .applied : .stale
        } catch {
            guard notificationFeedClient(for: macDeviceID) === client else {
                recordAppEvent(
                    .notificationFeedLoadFailed,
                    correlationID: macDeviceID,
                    startedAt: startedAt,
                    failure: .superseded
                )
                return .failed
            }
            notificationFeedLog.error(
                "list failed mac=\(macDeviceID, privacy: .public) error=\(String(describing: error), privacy: .private)"
            )
            recordAppEvent(
                .notificationFeedLoadFailed,
                correlationID: macDeviceID,
                startedAt: startedAt,
                failure: DiagnosticFailureKind.classify(error)
            )
            return .failed
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
            guard notificationFeedClient(for: target.ownerKey) === target.client else { return }
            let ids = notificationFeedSnapshotsByMac[target.ownerKey]?.items.map(\.notificationID) ?? []
            applyNotificationFeedReadStateMutation(
                macDeviceID: target.ownerKey,
                notificationIDs: ids,
                isRead: true,
                revision: response.revision
            )
            _ = scheduleNotificationFeedRefresh(
                macDeviceID: target.ownerKey,
                client: target.client,
                displayName: target.displayName
            )
            recordAppEvent(
                .notificationFeedItemMarkedRead,
                correlationID: target.ownerKey,
                count: ids.count
            )
        } catch {
            notificationFeedLog.error(
                "mark all read failed mac=\(target.macDeviceID, privacy: .public) error=\(String(describing: error), privacy: .private)"
            )
            recordAppEvent(
                .notificationFeedItemMarkedRead,
                correlationID: target.ownerKey,
                failure: DiagnosticFailureKind.classify(error)
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
           let ownerKey = normalizedForegroundNotificationFeedOwnerKey(),
           supportedHostCapabilities.contains(Self.notificationFeedCapability) {
            targets.append(NotificationFeedClientTarget(
                macDeviceID: MobilePairedMac.pairingIdentity(from: ownerKey).macDeviceID,
                instanceTag: activeMacInstanceTag,
                displayName: notificationFeedDisplayName(for: ownerKey),
                ownerKey: ownerKey,
                client: client
            ))
        }
        for (ownerKey, subscription) in secondaryMacSubscriptions
        where subscription.client !== remoteClient
            && subscription.supportedHostCapabilities.contains(
                Self.notificationFeedCapability
            ) {
            targets.append(NotificationFeedClientTarget(
                macDeviceID: subscription.macDeviceID,
                instanceTag: subscription.storedInstanceTag,
                displayName: notificationFeedDisplayName(for: ownerKey.pairingID),
                ownerKey: ownerKey.pairingID,
                client: subscription.client
            ))
        }
        return targets
    }

    private func notificationFeedTarget(for macDeviceID: String) -> NotificationFeedClientTarget? {
        guard let client = notificationFeedClient(for: macDeviceID),
              notificationFeedClientSupportsCapability(macDeviceID: macDeviceID) else { return nil }
        return NotificationFeedClientTarget(
            macDeviceID: MobilePairedMac.pairingIdentity(from: macDeviceID).macDeviceID,
            instanceTag: notificationFeedInstanceTag(forOwnerKey: macDeviceID),
            displayName: notificationFeedDisplayName(for: macDeviceID),
            ownerKey: macDeviceID,
            client: client
        )
    }

    /// The pairing tag behind a feed key: the foreground connection's tag, or
    /// the secondary subscription's proven tag. `ownerKey` is the feed-map
    /// key: the foreground's normalized device id, or a secondary
    /// subscription's pairing id.
    private func notificationFeedInstanceTag(forOwnerKey ownerKey: String) -> String? {
        if normalizedForegroundNotificationFeedOwnerKey() == ownerKey {
            return activeMacInstanceTag
        }
        return secondaryMacSubscriptions[MacPairingKey(pairingID: ownerKey)]?.storedInstanceTag
    }

    /// The feed-map key that owns `item`: the foreground key when the item is
    /// the foreground pairing's, else the owning secondary's pairing id, else
    /// the item's device id (legacy rows).
    private func notificationFeedOwnerKey(for item: MobileNotificationFeedItem) -> String {
        if let foreground = normalizedForegroundNotificationFeedOwnerKey(),
           foreground == MobilePairedMac.pairingID(
               macDeviceID: item.macDeviceID,
               instanceTag: item.macInstanceTag
           ),
           macInstanceTagAuthority.sameStoredAuthority(
               item.macInstanceTag, activeMacInstanceTag
           ) {
            return foreground
        }
        let pairingKey = MobilePairedMac.pairingID(
            macDeviceID: item.macDeviceID, instanceTag: item.macInstanceTag
        )
        if secondaryMacSubscriptions[MacPairingKey(pairingID: pairingKey)] != nil {
            return pairingKey
        }
        // Always retain the item's canonical pairing id, including when its
        // Mac is offline. A bare wire device id can resolve a sibling build's
        // client after teardown and mutate notification state on the wrong
        // app instance.
        return pairingKey
    }

    private func notificationFeedClient(for macDeviceID: String) -> MobileCoreRPCClient? {
        if normalizedForegroundNotificationFeedOwnerKey() == macDeviceID {
            return remoteClient
        }
        guard let subscription =
                secondaryMacSubscriptions[MacPairingKey(pairingID: macDeviceID)],
              !subscription.isTransitioningToFocus else {
            return nil
        }
        return subscription.client
    }

    private func notificationFeedClientSupportsCapability(macDeviceID: String) -> Bool {
        if normalizedForegroundNotificationFeedOwnerKey() == macDeviceID {
            return supportedHostCapabilities.contains(Self.notificationFeedCapability)
        }
        return secondaryMacSubscriptions[MacPairingKey(pairingID: macDeviceID)]?
            .supportedHostCapabilities.contains(Self.notificationFeedCapability) == true
    }

    private func notificationFeedConnectionStatus(for macDeviceID: String) -> MobileMacConnectionStatus {
        if normalizedForegroundNotificationFeedOwnerKey() == macDeviceID {
            return remoteClient == nil ? .unavailable : macConnectionStatus
        }
        if secondaryMacSubscriptions[MacPairingKey(pairingID: macDeviceID)] != nil {
            return .connected
        }
        return workspacesByMac[MacPairingKey(pairingID: macDeviceID)]?.status ?? .unavailable
    }

    private func normalizedForegroundNotificationFeedMacID() -> String? {
        let raw = foregroundMacDeviceID ?? activeTicket?.macDeviceID
        return normalizedOptionalIdentifier(raw)
    }

    /// Exact feed owner key for the foreground app instance. The feed maps use
    /// this key, never a bare physical device id, so a Stable snapshot cannot
    /// be reused by Nightly after a foreground switch.
    private func normalizedForegroundNotificationFeedOwnerKey() -> String? {
        guard let deviceID = normalizedForegroundNotificationFeedMacID() else {
            return nil
        }
        return MobilePairedMac.pairingID(
            macDeviceID: deviceID,
            instanceTag: activeMacInstanceTag
        )
    }

    private func notificationFeedDisplayName(for macDeviceID: String) -> String {
        let raw: String?
        if normalizedForegroundNotificationFeedOwnerKey() == macDeviceID {
            raw = activeTicket?.macDisplayName ?? connectedHostName
        } else {
            let ownerKey = MacPairingKey(pairingID: macDeviceID)
            raw = workspacesByMac[ownerKey]?.displayName
                ?? pairedMacs.first(where: { MacPairingKey($0) == ownerKey })?.displayName
        }
        return normalizedDisplayName(
            raw,
            fallback: MobilePairedMac.pairingIdentity(from: macDeviceID).macDeviceID
        )
    }

    private func resolvedNotificationFeedStatus() -> MobileNotificationFeedStatus {
        var connectedClientIDs = Set(
            secondaryMacSubscriptions.map {
                ObjectIdentifier($0.value.client)
            }
        )
        if let remoteClient {
            connectedClientIDs.insert(ObjectIdentifier(remoteClient))
        }
        let connectedClientCount = connectedClientIDs.count
        // Demonstration content is a live feed source without an RPC client:
        // with no real Macs connected (or none capable), a seeded demo
        // snapshot keeps the feed presentable instead of "unavailable".
        guard connectedClientCount > 0 else {
            return demonstrationNotificationFeedSeeded ? .ready : .unavailable
        }
        let targets = notificationFeedTargets()
        guard !targets.isEmpty else {
            return demonstrationNotificationFeedSeeded ? .ready : .requiresMacUpdate
        }
        let targetOwnerKeys = Set(targets.map(\.ownerKey))
        if notificationFeedItems.isEmpty,
           notificationFeedSuccessfulMacIDs.isDisjoint(with: targetOwnerKeys) {
            return .unavailable
        }
        return targets.count < connectedClientCount ? .requiresMacUpdate : .ready
    }

    private func normalizedDisplayName(_ value: String?, fallback: String) -> String {
        normalizedOptionalText(
            value,
            limitedToUTF8Bytes: mobileShellNotificationFeedMetadataByteLimit
        ) ?? mobileShellNotificationFeedString(
            fallback.trimmingCharacters(in: .whitespacesAndNewlines),
            limitedToUTF8Bytes: mobileShellNotificationFeedMetadataByteLimit
        )
    }

    private func normalizedIdentifier(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.utf8.count <= mobileShellNotificationFeedIdentifierByteLimit else {
            return nil
        }
        return trimmed
    }

    private func normalizedOptionalIdentifier(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              trimmed.utf8.count <= mobileShellNotificationFeedIdentifierByteLimit else {
            return nil
        }
        return trimmed
    }

    private func normalizedOptionalText(
        _ value: String?,
        limitedToUTF8Bytes maxBytes: Int
    ) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return mobileShellNotificationFeedString(trimmed, limitedToUTF8Bytes: maxBytes)
    }
}

nonisolated private func mobileShellNotificationFeedListStringLimits() -> MobileNotificationFeedListStringLimits {
    MobileNotificationFeedListStringLimits(
        identifierByteLimit: mobileShellNotificationFeedIdentifierByteLimit,
        titleByteLimit: mobileShellNotificationFeedTitleByteLimit,
        subtitleByteLimit: mobileShellNotificationFeedSubtitleByteLimit,
        bodyByteLimit: mobileShellNotificationFeedBodyByteLimit,
        metadataByteLimit: mobileShellNotificationFeedMetadataByteLimit
    )
}

private func mobileShellNotificationFeedString(_ value: String, limitedToUTF8Bytes maxBytes: Int) -> String {
    guard maxBytes >= 0, value.utf8.count > maxBytes else { return value }
    var byteCount = 0
    var endIndex = value.startIndex
    while endIndex < value.endIndex {
        let nextIndex = value.index(after: endIndex)
        let characterByteCount = value[endIndex..<nextIndex].utf8.count
        guard byteCount + characterByteCount <= maxBytes else { break }
        byteCount += characterByteCount
        endIndex = nextIndex
    }
    return String(value[..<endIndex])
}
