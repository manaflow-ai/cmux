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
        let targets = agentFeedTargets()
        guard !targets.isEmpty else {
            recomputeAgentFeedItems()
            agentFeedStatus = connectedAgentFeedMacCount > 0 ? .requiresMacUpdate : .unavailable
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
              let target = agentFeedTarget(for: ownerKey(for: item)) else { return }
        agentFeedMutationStates[item.id] = .sending
        var params: [String: Any] = [
            "item_id": item.wire.id.uuidString,
            "request_id": requestID,
        ]
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
            await fetchAgentFeed(target)
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
        navigateToWorkspaceForDeeplink(workspaceID, origin: .notificationFeed)
        if let surfaceID = item.wire.surfaceID,
           workspace(workspaceID, containsSurfaceID: surfaceID) {
            selectTerminal(MobileTerminalPreview.ID(rawValue: surfaceID))
        }
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
    }

    func resetAgentFeed() {
        for task in agentFeedRefreshTasksByMac.values { task.cancel() }
        agentFeedRefreshTasksByMac = [:]
        agentFeedSnapshotsByMac = [:]
        agentFeedKnownRevisionsByMac = [:]
        agentFeedItems = []
        agentFeedDrafts = [:]
        agentFeedMutationStates = [:]
        agentFeedStatus = .idle
    }

    private func scheduleAgentFeedRefresh(_ target: AgentFeedTarget) -> Task<Void, Never> {
        if let existing = agentFeedRefreshTasksByMac[target.ownerKey] { return existing }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.fetchAgentFeed(target)
            self.agentFeedRefreshTasksByMac[target.ownerKey] = nil
            self.agentFeedStatus = self.resolvedAgentFeedStatus()
        }
        agentFeedRefreshTasksByMac[target.ownerKey] = task
        return task
    }

    private func fetchAgentFeed(_ target: AgentFeedTarget, staleRetryBudget: Int = 1) async {
        do {
            let request = try MobileCoreRPCClient.requestData(method: "workstream.feed.list", params: [:])
            let data = try await target.client.sendRequest(request)
            let response = try MobileWorkstreamFeedListResponse.decode(data)
            guard agentFeedClient(for: target.ownerKey) === target.client else { return }
            let invalidatedRevision = agentFeedKnownRevisionsByMac[target.ownerKey] ?? 0
            let rows = response.items.prefix(MobileAgentFeedAggregation.maxItemCount).map { wire in
                MobileAgentFeedItem(
                    macDeviceID: target.macDeviceID,
                    macInstanceTag: target.instanceTag,
                    macDisplayName: target.displayName,
                    connectionStatus: .connected,
                    wire: wire
                )
            }
            agentFeedSnapshotsByMac[target.ownerKey] = AgentFeedMacSnapshot(
                revision: response.revision,
                items: rows
            )
            // A Mac process relaunch resets its revision namespace. The list is
            // authoritative, so adopt its cursor instead of retaining a larger
            // revision from the previous process forever.
            agentFeedKnownRevisionsByMac[target.ownerKey] = response.revision
            recomputeAgentFeedItems()
            if response.revision < invalidatedRevision, staleRetryBudget > 0 {
                await fetchAgentFeed(target, staleRetryBudget: staleRetryBudget - 1)
            }
        } catch {
            agentFeedLog.error(
                "list failed mac=\(target.macDeviceID, privacy: .public) error=\(String(describing: error), privacy: .private)"
            )
            if agentFeedSnapshotsByMac[target.ownerKey] == nil { agentFeedStatus = .failed }
        }
    }

    private var connectedAgentFeedMacCount: Int {
        (remoteClient == nil ? 0 : 1) + secondaryMacSubscriptions.count
    }

    private func resolvedAgentFeedStatus() -> MobileAgentFeedStatus {
        guard connectedAgentFeedMacCount > 0 else {
            return agentFeedItems.isEmpty ? .unavailable : .offlineCached
        }
        let capable = agentFeedTargets().count
        guard capable > 0 else { return .requiresMacUpdate }
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
}

private extension MobileWorkstreamFeedPayload {
    var requestID: String? {
        switch self {
        case .permission(let id, _, _, _), .exitPlan(let id, _, _, _), .question(let id, _): id
        default: nil
        }
    }
}
