import CmuxMobilePairedMac
import CmuxMobileRPC
public import CmuxMobileShellModel
import Foundation
internal import OSLog

nonisolated private let agentFeedLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "dev.cmux.ios",
    category: "agent-feed"
)

private struct AgentFeedTarget {
    let ownerKey: String
    let macDeviceID: String
    let instanceTag: String?
    let displayName: String
    let client: MobileCoreRPCClient
}

@MainActor
extension MobileShellComposite {
    static let agentFeedCapability = "workstream.feed.v1"

    /// Fetches all capable Macs and retains cached snapshots from offline Macs.
    public func refreshAgentFeed() async {
        await restoreAgentFeedCacheIfNeeded()
        let targets = agentFeedTargets()
        guard !targets.isEmpty else {
            recomputeAgentFeedItems()
            if agentFeedItems.isEmpty {
                agentFeedStatus = connectedAgentFeedMacCount > 0 ? .requiresMacUpdate : .unavailable
            } else {
                agentFeedStatus = connectedAgentFeedMacCount > 0 ? .requiresMacUpdate : .offlineCached
            }
            return
        }
        agentFeedStatus = .loading
        let tasks = targets.map { target in
            scheduleAgentFeedRefresh(target)
        }
        for task in tasks { await task.value }
        recomputeAgentFeedItems()
        agentFeedStatus = resolvedAgentFeedStatus()
    }

    /// Loads one persisted 300-item history page from every eligible Mac.
    public func loadOlderAgentFeed() async {
        guard !agentFeedIsLoadingOlder else { return }
        let targets = agentFeedTargets().filter { target in
            agentFeedSnapshotsByMac[target.ownerKey]?.hasMore == true
                && agentFeedSnapshotsByMac[target.ownerKey]?.nextCursor != nil
        }
        guard !targets.isEmpty else {
            recomputeAgentFeedPagingState()
            return
        }
        agentFeedIsLoadingOlder = true
        defer {
            agentFeedIsLoadingOlder = false
            recomputeAgentFeedPagingState()
        }
        for target in targets {
            guard let cursor = agentFeedSnapshotsByMac[target.ownerKey]?.nextCursor else { continue }
            await fetchAgentFeed(target, cursor: cursor, appending: true)
        }
        agentFeedStatus = resolvedAgentFeedStatus()
    }

    /// Coalesces invalidations per Mac onto one list request.
    func handleAgentFeedChangedEvent(
        _ event: MobileEventEnvelope,
        ownerKey: String,
        client: MobileCoreRPCClient
    ) {
        guard event.topic == "workstream.feed.changed",
              let data = event.payloadJSON,
              let changed = MobileWorkstreamFeedChangedEvent.decode(data),
              agentFeedClient(for: ownerKey) === client,
              changed.revision > (agentFeedKnownRevisionsByMac[ownerKey] ?? 0),
              let target = agentFeedTarget(for: ownerKey) else { return }
        agentFeedKnownRevisionsByMac[ownerKey] = changed.revision
        _ = scheduleAgentFeedRefresh(target)
    }

    func scheduleForegroundAgentFeedRefresh(client: MobileCoreRPCClient) {
        guard supportedHostCapabilities.contains(Self.agentFeedCapability),
              remoteClient === client,
              let target = agentFeedTargets().first(where: { $0.client === client }) else { return }
        _ = scheduleAgentFeedRefresh(target)
    }

    func scheduleSecondaryAgentFeedRefresh(
        ownerKey: String,
        client: MobileCoreRPCClient
    ) {
        guard let target = agentFeedTarget(for: ownerKey), target.client === client else { return }
        _ = scheduleAgentFeedRefresh(target)
    }

    /// Sends one exact permission, plan, or question decision. No optimistic
    /// resolution is applied; the authoritative list acknowledgement wins.
    public func sendAgentFeedAction(
        _ action: MobileAgentFeedAction,
        for item: MobileAgentFeedItem
    ) async {
        guard agentFeedMutationStates[item.id] != .sending,
              item.wire.status.isPending,
              let requestID = item.wire.payload.requestID,
              let workspaceID = item.wire.workspaceID,
              let surfaceID = item.wire.surfaceID,
              let target = agentFeedTarget(for: ownerKey(for: item)) else { return }
        agentFeedMutationStates[item.id] = .sending
        var params: [String: Any] = [
            "item_id": item.wire.id.uuidString,
            "request_id": requestID,
        ]
        params["workspace_id"] = workspaceID
        params["surface_id"] = surfaceID
        switch action {
        case .permission(let mode):
            params["kind"] = "permission"; params["mode"] = mode
        case .exitPlan(let mode, let feedback):
            params["kind"] = "exit_plan"; params["mode"] = mode
            if let feedback, !feedback.isEmpty { params["feedback"] = feedback }
        case .question(let selections):
            params["kind"] = "question"; params["selections"] = selections
        }
        do {
            let request = try MobileCoreRPCClient.requestData(method: "workstream.feed.action", params: params)
            _ = try await target.client.sendRequest(request)
            agentFeedMutationStates[item.id] = .idle
            await scheduleAgentFeedRefresh(target).value
        } catch {
            agentFeedMutationStates[item.id] = .failed(message: String(describing: error))
        }
    }

    /// Sends a multiline reply once to the item snapshot's pinned route.
    public func sendAgentFeedReply(for item: MobileAgentFeedItem) async {
        guard agentFeedMutationStates[item.id] != .sending,
              let workspaceID = item.wire.workspaceID,
              let surfaceID = item.wire.surfaceID,
              let draft = agentFeedDrafts[item.id],
              !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let target = agentFeedTarget(for: ownerKey(for: item)) else { return }
        agentFeedMutationStates[item.id] = .sending
        do {
            let request = try MobileCoreRPCClient.requestData(
                method: "workstream.feed.reply",
                params: [
                    "item_id": item.wire.id.uuidString,
                    "workstream_id": item.wire.workstreamID,
                    "workspace_id": workspaceID,
                    "surface_id": surfaceID,
                    "text": draft,
                ]
            )
            _ = try await target.client.sendRequest(request)
            agentFeedDrafts[item.id] = nil
            agentFeedMutationStates[item.id] = .idle
        } catch {
            agentFeedMutationStates[item.id] = .failed(message: String(describing: error))
        }
    }

    /// Opens the exact Mac/workspace/surface and leaves the Feed navigation
    /// stack intact so Back returns to its filter and expanded-card state.
    public func openAgentFeedItem(_ item: MobileAgentFeedItem) async -> Bool {
        let foregroundMatches = item.macDeviceID == foregroundMacDeviceID
            && macInstanceTagAuthority.sameStoredAuthority(item.macInstanceTag, activeMacInstanceTag)
        if !foregroundMatches,
           !(await switchToMac(macDeviceID: item.macDeviceID, instanceTag: item.macInstanceTag)) {
            return false
        }
        guard let remoteWorkspaceID = item.wire.workspaceID,
              let workspaceID = rowWorkspaceID(
                forRemoteWorkspaceID: MobileWorkspacePreview.ID(rawValue: remoteWorkspaceID),
                macDeviceID: item.macDeviceID,
                instanceTag: item.macInstanceTag
              ) else { return false }
        guard let surfaceID = item.wire.surfaceID,
              workspace(workspaceID, containsSurfaceID: surfaceID) else { return false }
        navigateToWorkspaceForDeeplink(workspaceID, origin: .notificationFeed)
        selectTerminal(MobileTerminalPreview.ID(rawValue: surfaceID))
        return true
    }

    func recomputeAgentFeedItems() {
        agentFeedItems = agentFeedAggregation.items(from: agentFeedSnapshotsByMac.values.map(\.items)).map { item in
            let isForeground = item.macDeviceID == foregroundMacDeviceID
                && macInstanceTagAuthority.sameStoredAuthority(item.macInstanceTag, activeMacInstanceTag)
            let status = isForeground
                ? macConnectionStatus
                : macConnectionStatuses[item.macDeviceID] ?? .unavailable
            return MobileAgentFeedItem(
                macDeviceID: item.macDeviceID,
                macInstanceTag: item.macInstanceTag,
                macDisplayName: item.macDisplayName,
                connectionStatus: status,
                wire: item.wire
            )
        }
        let retainedIDs = Set(agentFeedItems.map(\.id))
        agentFeedDrafts = agentFeedDrafts.filter { retainedIDs.contains($0.key) }
        agentFeedMutationStates = agentFeedMutationStates.filter { retainedIDs.contains($0.key) }
        recomputeAgentFeedPagingState()
    }

    func resetAgentFeed() {
        resetAgentFeedForScopeChange()
        let previousClear = agentFeedCacheClearTask
        let token = UUID()
        agentFeedCacheClearToken = token
        agentFeedCacheClearTask = Task { [agentFeedCacheStore] in
            await previousClear?.value
            await agentFeedCacheStore.clearAll()
        }
    }

    /// Drops old-team in-memory rows without deleting that team's scoped cache,
    /// so switching back can restore it while the new team never sees it.
    func resetAgentFeedForScopeChange() {
        agentFeedRefreshTasks.cancelAll()
        agentFeedSnapshotsByMac = [:]
        agentFeedKnownRevisionsByMac = [:]
        agentFeedFailedOwnerKeys = []
        agentFeedItems = []
        agentFeedDrafts = [:]
        agentFeedMutationStates = [:]
        agentFeedStatus = .idle
        agentFeedHasMoreItems = false
        agentFeedCanLoadOlder = false
        agentFeedIsLoadingOlder = false
        agentFeedCacheScopeKey = nil
    }

    private func scheduleAgentFeedRefresh(_ target: AgentFeedTarget) -> Task<Void, Never> {
        agentFeedRefreshTasks.schedule(ownerKey: target.ownerKey) { @MainActor [weak self] in
            guard let self else { return }
            await self.restoreAgentFeedCacheIfNeeded()
            guard !Task.isCancelled else { return }
            await self.fetchAgentFeed(target)
            guard !Task.isCancelled else { return }
            self.agentFeedStatus = self.resolvedAgentFeedStatus()
        }
    }

    private func fetchAgentFeed(
        _ target: AgentFeedTarget,
        cursor: String? = nil,
        appending: Bool = false
    ) async {
        do {
            var params: [String: Any] = [:]
            if let cursor { params["cursor"] = cursor }
            let request = try MobileCoreRPCClient.requestData(method: "workstream.feed.list", params: params)
            let data = try await target.client.sendRequest(request)
            let response = try await Task.detached {
                try MobileWorkstreamFeedListResponse.decode(data)
            }.value
            guard !Task.isCancelled,
                  agentFeedClient(for: target.ownerKey) === target.client else { return }
            var pages: MobileAgentFeedPageAccumulator
            if var existing = agentFeedSnapshotsByMac[target.ownerKey]?.pages {
                if appending {
                    existing.append(response)
                } else {
                    existing.applyFirstPage(response)
                }
                pages = existing
            } else {
                pages = MobileAgentFeedPageAccumulator(response: response)
            }
            let rows = pages.items.map { wire in
                MobileAgentFeedItem(
                    macDeviceID: target.macDeviceID,
                    macInstanceTag: target.instanceTag,
                    macDisplayName: target.displayName,
                    connectionStatus: .connected,
                    wire: wire
                )
            }
            agentFeedSnapshotsByMac[target.ownerKey] = AgentFeedMacSnapshot(
                pages: pages,
                items: rows
            )
            // A Mac process relaunch resets its revision namespace. The list is
            // authoritative, so adopt its cursor instead of retaining a larger
            // revision from the previous process forever.
            agentFeedKnownRevisionsByMac[target.ownerKey] = response.revision
            agentFeedFailedOwnerKeys.remove(target.ownerKey)
            recomputeAgentFeedItems()
            if !appending {
                let sanitized = await Task.detached {
                    Self.sanitizedAgentFeedCacheData(data)
                }.value
                guard !Task.isCancelled else { return }
                await persistAgentFeedSnapshot(sanitized, target: target)
            }
        } catch {
            guard !Task.isCancelled else { return }
            agentFeedFailedOwnerKeys.insert(target.ownerKey)
            agentFeedLog.error(
                "list failed mac=\(target.macDeviceID, privacy: .public) error=\(String(describing: error), privacy: .private)"
            )
            agentFeedStatus = agentFeedSnapshotsByMac[target.ownerKey] == nil ? .failed : .offlineCached
        }
    }

    private func restoreAgentFeedCacheIfNeeded() async {
        await awaitAgentFeedCacheClearIfNeeded()
        guard agentFeedSnapshotsByMac.isEmpty,
              let scope = await currentScopeSnapshot() else { return }
        let scopeKey = pairedMacScopeKey(scope)
        agentFeedCacheScopeKey = scopeKey
        let cached = await agentFeedCacheStore.load(scopeKey: scopeKey)
        guard await isScopeCurrent(scope) else { return }
        let decoded: [(AgentFeedCachedSnapshot, MobileWorkstreamFeedListResponse)] = await Task.detached {
            cached.compactMap { snapshot in
                guard let response = try? MobileWorkstreamFeedListResponse.decode(snapshot.responseData) else {
                    return nil
                }
                return (snapshot, response)
            }
        }.value
        guard !Task.isCancelled else { return }
        for (snapshot, response) in decoded {
            let rows = response.items.prefix(MobileAgentFeedAggregation.maxItemCount).map { wire in
                MobileAgentFeedItem(
                    macDeviceID: snapshot.macDeviceID,
                    macInstanceTag: snapshot.instanceTag,
                    macDisplayName: snapshot.displayName,
                    connectionStatus: .unavailable,
                    wire: wire
                )
            }
            agentFeedSnapshotsByMac[snapshot.ownerKey] = AgentFeedMacSnapshot(
                pages: MobileAgentFeedPageAccumulator(response: response),
                items: rows
            )
            agentFeedKnownRevisionsByMac[snapshot.ownerKey] = response.revision
        }
        recomputeAgentFeedItems()
        if !agentFeedItems.isEmpty { agentFeedStatus = .offlineCached }
    }

    private func persistAgentFeedSnapshot(_ data: Data, target: AgentFeedTarget) async {
        await awaitAgentFeedCacheClearIfNeeded()
        guard !data.isEmpty,
              let scope = await currentScopeSnapshot(),
              await isScopeCurrent(scope) else { return }
        let scopeKey = pairedMacScopeKey(scope)
        agentFeedCacheScopeKey = scopeKey
        await agentFeedCacheStore.upsert(
            AgentFeedCachedSnapshot(
                ownerKey: target.ownerKey,
                macDeviceID: target.macDeviceID,
                instanceTag: target.instanceTag,
                displayName: target.displayName,
                responseData: data,
                cachedAt: Date()
            ),
            scopeKey: scopeKey
        )
    }

    /// Removes raw tool input before writing a host response to disk. Cards use
    /// the host-produced redacted summary, so retaining raw values is needless.
    nonisolated static func sanitizedAgentFeedCacheData(_ data: Data) -> Data {
        guard var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              var items = root["items"] as? [[String: Any]] else { return Data() }
        for index in items.indices {
            items[index]["tool_input"] = nil
            items[index]["tool_input_capabilities"] = nil
        }
        root["items"] = items
        return (try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])) ?? Data()
    }

    private var connectedAgentFeedMacCount: Int {
        (remoteClient == nil ? 0 : 1) + secondaryMacSubscriptions.count
    }

    private func recomputeAgentFeedPagingState() {
        agentFeedHasMoreItems = agentFeedSnapshotsByMac.values.contains { $0.hasMore }
        let eligibleOwnerKeys = Set(agentFeedTargets().map(\.ownerKey))
        agentFeedCanLoadOlder = agentFeedSnapshotsByMac.contains { ownerKey, snapshot in
            eligibleOwnerKeys.contains(ownerKey) && snapshot.hasMore && snapshot.nextCursor != nil
        }
    }

    private func resolvedAgentFeedStatus() -> MobileAgentFeedStatus {
        guard connectedAgentFeedMacCount > 0 else {
            return agentFeedItems.isEmpty ? .unavailable : .offlineCached
        }
        let capable = agentFeedTargets().count
        guard capable > 0 else { return .requiresMacUpdate }
        let failedCount = agentFeedTargets().lazy.filter { self.agentFeedFailedOwnerKeys.contains($0.ownerKey) }.count
        if failedCount == capable { return agentFeedItems.isEmpty ? .failed : .offlineCached }
        if failedCount > 0 { return .partial }
        if capable < connectedAgentFeedMacCount { return .partial }
        return .ready
    }

    private func agentFeedTargets() -> [AgentFeedTarget] {
        var result: [AgentFeedTarget] = []
        if let client = remoteClient,
           supportedHostCapabilities.contains(Self.agentFeedCapability),
           let macDeviceID = foregroundMacDeviceID ?? activeTicket?.macDeviceID {
            result.append(AgentFeedTarget(
                ownerKey: macDeviceID,
                macDeviceID: macDeviceID,
                instanceTag: activeMacInstanceTag,
                displayName: activeTicket?.macDisplayName ?? connectedHostName,
                client: client
            ))
        }
        for (key, subscription) in secondaryMacSubscriptions
        where subscription.supportedHostCapabilities.contains(Self.agentFeedCapability) {
            result.append(AgentFeedTarget(
                ownerKey: key.pairingID,
                macDeviceID: subscription.macDeviceID,
                instanceTag: subscription.storedInstanceTag,
                displayName: subscription.displayName ?? subscription.macDeviceID,
                client: subscription.client
            ))
        }
        return result
    }

    private func agentFeedTarget(for ownerKey: String) -> AgentFeedTarget? {
        agentFeedTargets().first { $0.ownerKey == ownerKey }
    }

    private func agentFeedClient(for ownerKey: String) -> MobileCoreRPCClient? {
        agentFeedTarget(for: ownerKey)?.client
    }

    private func ownerKey(for item: MobileAgentFeedItem) -> String {
        if item.macDeviceID == foregroundMacDeviceID,
           macInstanceTagAuthority.sameStoredAuthority(item.macInstanceTag, activeMacInstanceTag) {
            return item.macDeviceID
        }
        return MobilePairedMac.pairingID(macDeviceID: item.macDeviceID, instanceTag: item.macInstanceTag)
    }

    func removeAgentFeedSnapshot(ownerKey: String) {
        agentFeedRefreshTasks.cancel(ownerKey: ownerKey)
        agentFeedSnapshotsByMac[ownerKey] = nil
        agentFeedKnownRevisionsByMac[ownerKey] = nil
        agentFeedFailedOwnerKeys.remove(ownerKey)
        recomputeAgentFeedItems()
        agentFeedStatus = resolvedAgentFeedStatus()
    }

    func resetForegroundAgentFeedIfInstanceChanged(
        previousDeviceID: String?,
        previousTag: String?,
        newDeviceID: String?,
        newTag: String?
    ) {
        guard let newDeviceID, !newDeviceID.isEmpty,
              previousDeviceID == newDeviceID,
              !macInstanceTagAuthority.sameStoredAuthority(previousTag, newTag) else { return }
        removeAgentFeedSnapshot(ownerKey: newDeviceID)
    }

    private func awaitAgentFeedCacheClearIfNeeded() async {
        guard let task = agentFeedCacheClearTask,
              let token = agentFeedCacheClearToken else { return }
        await task.value
        guard agentFeedCacheClearToken == token else { return }
        agentFeedCacheClearTask = nil
        agentFeedCacheClearToken = nil
    }
}

private extension MobileWorkstreamFeedPayload {
    var requestID: String? {
        switch self {
        case .permission(let id, _, _, _), .exitPlan(let id, _, _, _), .question(let id, _): id
        default: nil
        }
    }
}
