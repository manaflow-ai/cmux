import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileRPC
public import CmuxMobileShellModel
import Foundation
internal import OSLog

private let agentFeedLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "dev.cmux.ios",
    category: "agent-feed"
)

nonisolated private let mobileShellAgentFeedIdentifierByteLimit = 512
nonisolated private let mobileShellAgentFeedPrimaryTextByteLimit = 8_192
nonisolated private let mobileShellAgentFeedSecondaryTextByteLimit = 2_048
nonisolated private let mobileShellAgentFeedMetadataByteLimit = 512
nonisolated private let mobileShellAgentFeedMaxItemCount = 400

/// The phone-side mirror of the Mac's workstream Feed (`feed.list` +
/// `feed.changed` + the reply verbs). Mirrors the notification feed's
/// per-Mac snapshot/revision discipline with a simpler refresh ladder:
/// one in-flight list per Mac plus one coalesced trailing pass, re-armed
/// by `feed.changed` events, connection readiness, and explicit refreshes.
@MainActor
extension MobileShellComposite {
    static let agentFeedCapability = "feed.v1"

    struct AgentFeedClientTarget {
        let macDeviceID: String
        let instanceTag: String?
        let displayName: String
        let ownerKey: String
        let client: MobileCoreRPCClient
    }

    // MARK: - Refresh

    /// Refreshes the agent feed from every currently connected capable Mac.
    /// A Mac that is offline keeps its last-known snapshot.
    public func refreshAgentFeed() async {
        let targets = agentFeedTargets()
        if targets.isEmpty {
            recomputeAgentFeedItems()
            agentFeedStatus = resolvedAgentFeedStatus()
            return
        }
        agentFeedStatus = .loading
        let tasks = targets.compactMap { target in
            scheduleAgentFeedRefresh(
                macDeviceID: target.ownerKey,
                client: target.client,
                displayName: target.displayName
            )
        }
        for task in tasks {
            await task.value
        }
        recomputeAgentFeedItems()
        agentFeedStatus = resolvedAgentFeedStatus()
    }

    /// Handles a revision-only feed invalidation from one specific Mac.
    func handleAgentFeedChangedEvent(
        _ event: MobileEventEnvelope,
        macDeviceID: String,
        client: MobileCoreRPCClient,
        displayName: String
    ) {
        guard event.topic == "feed.changed",
              let payload = event.payloadJSON,
              let changed = MobileAgentFeedChangedEvent.decode(payload),
              agentFeedClient(for: macDeviceID) === client else { return }
        let appliedRevision = agentFeedSnapshotsByMac[macDeviceID]?.revision ?? -1
        let knownRevision = agentFeedKnownRevisionsByMac[macDeviceID] ?? -1
        guard changed.revision > max(appliedRevision, knownRevision) else { return }
        agentFeedKnownRevisionsByMac[macDeviceID] = changed.revision
        _ = scheduleAgentFeedRefresh(
            macDeviceID: macDeviceID,
            client: client,
            displayName: displayName
        )
    }

    /// Starts an initial fetch after a capable foreground connection is established.
    func scheduleForegroundAgentFeedRefresh(client: MobileCoreRPCClient) {
        guard let macDeviceID = normalizedForegroundNotificationFeedMacIDForEvent(),
              supportedHostCapabilities.contains(Self.agentFeedCapability),
              remoteClient === client else { return }
        if agentFeedStatus == .idle {
            agentFeedStatus = .loading
        }
        _ = scheduleAgentFeedRefresh(
            macDeviceID: macDeviceID,
            client: client,
            displayName: notificationFeedDisplayNameForForeground(macDeviceID: macDeviceID)
        )
    }

    /// Starts an initial fetch after a capable secondary connection is established.
    func scheduleSecondaryAgentFeedRefresh(
        macDeviceID: String,
        client: MobileCoreRPCClient,
        displayName: String?
    ) {
        let ownerKey = MacPairingKey(pairingID: macDeviceID)
        guard secondaryMacSubscriptions[ownerKey]?.client === client,
              client !== remoteClient,
              secondaryMacSubscriptions[ownerKey]?.supportedHostCapabilities
                  .contains(Self.agentFeedCapability) == true else { return }
        _ = scheduleAgentFeedRefresh(
            macDeviceID: macDeviceID,
            client: client,
            displayName: notificationFeedDisplayNameForSecondary(
                macDeviceID: macDeviceID,
                fallback: displayName
            )
        )
    }

    /// Cancels all agent-feed work and removes account-scoped content.
    func resetAgentFeed() {
        for task in agentFeedRefreshTasksByMac.values {
            task.cancel()
        }
        agentFeedRefreshTasksByMac = [:]
        agentFeedRefreshPendingMacIDs = []
        agentFeedKnownRevisionsByMac = [:]
        agentFeedSuccessfulMacIDs = []
        agentFeedSnapshotsByMac = [:]
        agentFeedPendingReplyRequestIDs = []
        agentFeedItems = []
        agentFeedStatus = .idle
    }

    /// Removes one hidden Mac's rows and cancels work that could restore them.
    func removeAgentFeedSnapshot(macDeviceID: String) {
        agentFeedRefreshTasksByMac[macDeviceID]?.cancel()
        agentFeedRefreshTasksByMac[macDeviceID] = nil
        agentFeedRefreshPendingMacIDs.remove(macDeviceID)
        agentFeedKnownRevisionsByMac[macDeviceID] = nil
        agentFeedSuccessfulMacIDs.remove(macDeviceID)
        agentFeedSnapshotsByMac[macDeviceID] = nil
        recomputeAgentFeedItems()
        if agentFeedItems.isEmpty, agentFeedStatus == .ready {
            agentFeedStatus = resolvedAgentFeedStatus()
        }
    }

    private func scheduleAgentFeedRefresh(
        macDeviceID: String,
        client: MobileCoreRPCClient,
        displayName: String
    ) -> Task<Void, Never>? {
        guard agentFeedClient(for: macDeviceID) === client,
              agentFeedClientSupportsCapability(macDeviceID: macDeviceID) else { return nil }
        if let task = agentFeedRefreshTasksByMac[macDeviceID] {
            agentFeedRefreshPendingMacIDs.insert(macDeviceID)
            return task
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            repeat {
                self.agentFeedRefreshPendingMacIDs.remove(macDeviceID)
                await self.fetchAgentFeed(
                    macDeviceID: macDeviceID,
                    client: client,
                    displayName: displayName
                )
            } while !Task.isCancelled
                && self.agentFeedClient(for: macDeviceID) === client
                && self.agentFeedRefreshPendingMacIDs.contains(macDeviceID)
            self.agentFeedRefreshTasksByMac[macDeviceID] = nil
            self.agentFeedRefreshPendingMacIDs.remove(macDeviceID)
            if self.agentFeedRefreshTasksByMac.isEmpty {
                self.agentFeedStatus = self.resolvedAgentFeedStatus()
            }
        }
        agentFeedRefreshTasksByMac[macDeviceID] = task
        return task
    }

    private func fetchAgentFeed(
        macDeviceID: String,
        client: MobileCoreRPCClient,
        displayName: String
    ) async {
        do {
            let request = try MobileCoreRPCClient.requestData(
                method: "feed.list",
                params: [:]
            )
            let data = try await client.sendRequest(request)
            let response = try MobileAgentFeedListResponse.decode(data)
            guard !Task.isCancelled,
                  agentFeedClient(for: macDeviceID) === client else { return }
            applyAgentFeedSnapshot(
                response,
                macDeviceID: macDeviceID,
                displayName: displayName
            )
        } catch {
            guard agentFeedClient(for: macDeviceID) === client else { return }
            agentFeedLog.error(
                "list failed mac=\(macDeviceID, privacy: .public) error=\(String(describing: error), privacy: .private)"
            )
        }
    }

    /// Applies a decoded snapshot if its revision is not stale. Internal so
    /// package tests can exercise the revision invariant without a transport.
    @discardableResult
    func applyAgentFeedSnapshot(
        _ response: MobileAgentFeedListResponse,
        macDeviceID: String,
        displayName: String
    ) -> Bool {
        guard let macDeviceID = agentFeedNormalizedIdentifier(macDeviceID) else { return false }
        let currentRevision = agentFeedSnapshotsByMac[macDeviceID]?.revision ?? -1
        let knownRevision = agentFeedKnownRevisionsByMac[macDeviceID] ?? -1
        guard response.revision >= knownRevision else {
            // An invalidation arrived while this list RPC was in flight; a
            // trailing pass is already armed via the pending set.
            agentFeedRefreshPendingMacIDs.insert(macDeviceID)
            return false
        }
        if response.revision < currentRevision {
            return true
        }

        let status = agentFeedConnectionStatus(for: macDeviceID)
        let identity = MobilePairedMac.pairingIdentity(from: macDeviceID)
        let itemMacDeviceID = identity.macDeviceID
        let itemInstanceTag = identity.instanceTag ?? agentFeedInstanceTag(forOwnerKey: macDeviceID)
        let macDisplayName = agentFeedNormalizedText(
            displayName,
            limitedToUTF8Bytes: mobileShellAgentFeedMetadataByteLimit
        ) ?? itemMacDeviceID

        var seenIDs = Set<MobileAgentFeedItemID>()
        var items: [MobileAgentFeedItem] = []
        items.reserveCapacity(min(response.items.count, mobileShellAgentFeedMaxItemCount))
        for wire in response.items.prefix(mobileShellAgentFeedMaxItemCount) {
            guard let item = agentFeedItem(
                from: wire,
                macDeviceID: itemMacDeviceID,
                macInstanceTag: itemInstanceTag,
                macDisplayName: macDisplayName,
                connectionStatus: status
            ) else { continue }
            guard seenIDs.insert(item.id).inserted else { continue }
            items.append(item)
        }
        items.sort { lhs, rhs in
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt > rhs.createdAt
            }
            return lhs.id < rhs.id
        }

        agentFeedSnapshotsByMac[macDeviceID] = AgentFeedMacSnapshot(
            revision: response.revision,
            items: items
        )
        agentFeedKnownRevisionsByMac[macDeviceID] = max(knownRevision, response.revision)
        agentFeedSuccessfulMacIDs.insert(macDeviceID)
        recomputeAgentFeedItems()
        return true
    }

    /// Rebuilds connection-state projections and deterministic cross-Mac ordering.
    func recomputeAgentFeedItems() {
        var merged: [MobileAgentFeedItem] = []
        for (macDeviceID, snapshot) in agentFeedSnapshotsByMac {
            let status = agentFeedConnectionStatus(for: macDeviceID)
            for item in snapshot.items {
                merged.append(
                    item.connectionStatus == status
                        ? item
                        : item.updating(connectionStatus: status)
                )
            }
        }
        merged.sort { lhs, rhs in
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt > rhs.createdAt
            }
            return lhs.id < rhs.id
        }
        if merged.count > mobileShellAgentFeedMaxItemCount {
            merged.removeSubrange(mobileShellAgentFeedMaxItemCount...)
        }
        agentFeedItems = merged
    }

    // MARK: - Replies

    /// Answers a pending permission row. Resolution flows through the same
    /// `FeedCoordinator.deliverReply` path the Mac Feed panel and CLI use.
    /// - Returns: Whether the reply was delivered to the owning Mac.
    @discardableResult
    public func submitAgentFeedPermissionReply(
        _ item: MobileAgentFeedItem,
        mode: String
    ) async -> Bool {
        guard let requestID = item.requestID else { return false }
        return await submitAgentFeedReply(
            item,
            method: "feed.permission.reply",
            params: ["request_id": requestID, "mode": mode],
            decision: MobileAgentFeedDecision(kind: "permission", mode: mode)
        )
    }

    /// Answers a pending question row with option ids or free text.
    @discardableResult
    public func submitAgentFeedQuestionReply(
        _ item: MobileAgentFeedItem,
        selections: [String]
    ) async -> Bool {
        guard let requestID = item.requestID, !selections.isEmpty else { return false }
        return await submitAgentFeedReply(
            item,
            method: "feed.question.reply",
            params: ["request_id": requestID, "selections": selections],
            decision: MobileAgentFeedDecision(kind: "question", selections: selections)
        )
    }

    /// Approves, revises, or denies a pending exit-plan row.
    @discardableResult
    public func submitAgentFeedExitPlanReply(
        _ item: MobileAgentFeedItem,
        mode: String,
        feedback: String? = nil
    ) async -> Bool {
        guard let requestID = item.requestID else { return false }
        var params: [String: Any] = ["request_id": requestID, "mode": mode]
        if let feedback, !feedback.isEmpty {
            params["feedback"] = feedback
        }
        return await submitAgentFeedReply(
            item,
            method: "feed.exit_plan.reply",
            params: params,
            decision: MobileAgentFeedDecision(kind: "exit_plan", mode: mode, feedback: feedback)
        )
    }

    /// Sends a free-text reply to a completed turn's terminal on the owning
    /// Mac, the same routing the push-notification inline reply uses.
    @discardableResult
    public func submitAgentFeedTerminalReply(
        _ item: MobileAgentFeedItem,
        text: String
    ) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let workspaceID = item.remoteWorkspaceID,
              let surfaceID = item.remoteSurfaceID,
              let target = agentFeedTarget(for: agentFeedOwnerKey(for: item)) else {
            return false
        }
        do {
            let request = try MobileCoreRPCClient.requestData(
                method: "mobile.terminal.input",
                params: [
                    "workspace_id": workspaceID,
                    "surface_id": surfaceID,
                    "text": trimmed + "\r",
                ]
            )
            _ = try await target.client.sendRequest(request)
            return true
        } catch {
            agentFeedLog.error(
                "terminal reply failed mac=\(item.macDeviceID, privacy: .public) error=\(String(describing: error), privacy: .private)"
            )
            return false
        }
    }

    private func submitAgentFeedReply(
        _ item: MobileAgentFeedItem,
        method: String,
        params: [String: Any],
        decision: MobileAgentFeedDecision
    ) async -> Bool {
        guard let requestID = item.requestID,
              !agentFeedPendingReplyRequestIDs.contains(requestID),
              let target = agentFeedTarget(for: agentFeedOwnerKey(for: item)) else {
            return false
        }
        agentFeedPendingReplyRequestIDs.insert(requestID)
        defer { agentFeedPendingReplyRequestIDs.remove(requestID) }
        do {
            let request = try MobileCoreRPCClient.requestData(method: method, params: params)
            _ = try await target.client.sendRequest(request)
            guard agentFeedClient(for: target.ownerKey) === target.client else { return true }
            // Optimistic local resolution; the scheduled refresh reconciles
            // against the Mac's authoritative feed.
            applyAgentFeedLocalResolution(
                ownerKey: target.ownerKey,
                requestID: requestID,
                decision: decision
            )
            _ = scheduleAgentFeedRefresh(
                macDeviceID: target.ownerKey,
                client: target.client,
                displayName: target.displayName
            )
            return true
        } catch {
            agentFeedLog.error(
                """
                reply failed method=\(method, privacy: .public) \
                mac=\(item.macDeviceID, privacy: .public) \
                error=\(String(describing: error), privacy: .private)
                """
            )
            return false
        }
    }

    /// Marks the pending row carrying `requestID` locally resolved. Internal
    /// so package tests can exercise the optimistic projection directly.
    func applyAgentFeedLocalResolution(
        ownerKey: String,
        requestID: String,
        decision: MobileAgentFeedDecision
    ) {
        guard var snapshot = agentFeedSnapshotsByMac[ownerKey] else { return }
        var didResolve = false
        snapshot.items = snapshot.items.map { item in
            guard item.requestID == requestID, item.status.isPending else { return item }
            didResolve = true
            return item.updating(status: .resolved(decision), updatedAt: Date())
        }
        guard didResolve else { return }
        agentFeedSnapshotsByMac[ownerKey] = snapshot
        recomputeAgentFeedItems()
    }

    // MARK: - Wire mapping

    private func agentFeedItem(
        from wire: MobileAgentFeedListItem,
        macDeviceID: String,
        macInstanceTag: String?,
        macDisplayName: String,
        connectionStatus: MobileMacConnectionStatus
    ) -> MobileAgentFeedItem? {
        guard let itemID = agentFeedNormalizedIdentifier(wire.id),
              let workstreamID = agentFeedNormalizedIdentifier(wire.workstreamID) else {
            return nil
        }
        let kind = MobileAgentFeedItemKind(rawValue: wire.kind) ?? .unsupported
        let status: MobileAgentFeedItemStatus
        switch wire.status {
        case "pending":
            status = .pending
        case "resolved":
            let decision = wire.decision.map {
                MobileAgentFeedDecision(
                    kind: $0.kind,
                    mode: $0.mode,
                    selections: $0.selections,
                    feedback: $0.feedback
                )
            }
            status = .resolved(decision ?? MobileAgentFeedDecision(kind: "unknown"))
        case "expired":
            status = .expired
        default:
            status = .telemetry
        }

        let questions = wire.questions.map { question in
            MobileAgentFeedQuestion(
                id: question.id,
                header: agentFeedNormalizedText(
                    question.header,
                    limitedToUTF8Bytes: mobileShellAgentFeedSecondaryTextByteLimit
                ),
                prompt: agentFeedString(
                    question.prompt,
                    limitedToUTF8Bytes: mobileShellAgentFeedSecondaryTextByteLimit
                ),
                multiSelect: question.multiSelect,
                options: question.options.map { option in
                    MobileAgentFeedQuestionOption(
                        id: option.id,
                        label: agentFeedString(
                            option.label,
                            limitedToUTF8Bytes: mobileShellAgentFeedMetadataByteLimit
                        ),
                        description: agentFeedNormalizedText(
                            option.description,
                            limitedToUTF8Bytes: mobileShellAgentFeedSecondaryTextByteLimit
                        )
                    )
                }
            )
        }

        var context: MobileAgentFeedContext?
        if let wireContext = wire.context {
            let mapped = MobileAgentFeedContext(
                lastUserMessage: agentFeedNormalizedText(
                    wireContext.lastUserMessage,
                    limitedToUTF8Bytes: mobileShellAgentFeedSecondaryTextByteLimit
                ),
                assistantPreamble: agentFeedNormalizedText(
                    wireContext.assistantPreamble,
                    limitedToUTF8Bytes: mobileShellAgentFeedSecondaryTextByteLimit
                ),
                planSummary: agentFeedNormalizedText(
                    wireContext.planSummary,
                    limitedToUTF8Bytes: mobileShellAgentFeedSecondaryTextByteLimit
                ),
                toolSummary: agentFeedNormalizedText(
                    wireContext.toolSummary,
                    limitedToUTF8Bytes: mobileShellAgentFeedSecondaryTextByteLimit
                ),
                permissionMode: agentFeedNormalizedText(
                    wireContext.permissionMode,
                    limitedToUTF8Bytes: mobileShellAgentFeedMetadataByteLimit
                )
            )
            context = mapped.isEmpty ? nil : mapped
        }

        return MobileAgentFeedItem(
            macDeviceID: macDeviceID,
            macInstanceTag: macInstanceTag,
            macDisplayName: macDisplayName,
            itemID: itemID,
            workstreamID: workstreamID,
            source: agentFeedString(
                wire.source,
                limitedToUTF8Bytes: mobileShellAgentFeedMetadataByteLimit
            ),
            kind: kind,
            status: status,
            createdAt: wire.createdAt,
            updatedAt: wire.updatedAt,
            title: agentFeedNormalizedText(
                wire.title,
                limitedToUTF8Bytes: mobileShellAgentFeedMetadataByteLimit
            ),
            cwd: agentFeedNormalizedText(
                wire.cwd,
                limitedToUTF8Bytes: mobileShellAgentFeedMetadataByteLimit
            ),
            requestID: agentFeedNormalizedText(
                wire.requestID,
                limitedToUTF8Bytes: mobileShellAgentFeedIdentifierByteLimit
            ),
            toolName: agentFeedNormalizedText(
                wire.toolName,
                limitedToUTF8Bytes: mobileShellAgentFeedMetadataByteLimit
            ),
            toolInput: agentFeedNormalizedText(
                wire.toolInput,
                limitedToUTF8Bytes: mobileShellAgentFeedPrimaryTextByteLimit
            ),
            toolResult: agentFeedNormalizedText(
                wire.toolResult,
                limitedToUTF8Bytes: mobileShellAgentFeedPrimaryTextByteLimit
            ),
            toolResultIsError: wire.toolResultIsError ?? false,
            plan: agentFeedNormalizedText(
                wire.plan,
                limitedToUTF8Bytes: mobileShellAgentFeedPrimaryTextByteLimit
            ),
            planSummary: agentFeedNormalizedText(
                wire.planSummary,
                limitedToUTF8Bytes: mobileShellAgentFeedSecondaryTextByteLimit
            ),
            defaultExitPlanMode: agentFeedNormalizedText(
                wire.defaultMode,
                limitedToUTF8Bytes: mobileShellAgentFeedMetadataByteLimit
            ),
            questions: questions,
            text: agentFeedNormalizedText(
                wire.text,
                limitedToUTF8Bytes: mobileShellAgentFeedPrimaryTextByteLimit
            ),
            stopReason: agentFeedNormalizedText(
                wire.reason,
                limitedToUTF8Bytes: mobileShellAgentFeedSecondaryTextByteLimit
            ),
            remoteWorkspaceID: agentFeedNormalizedText(
                wire.workspaceID,
                limitedToUTF8Bytes: mobileShellAgentFeedIdentifierByteLimit
            ),
            remoteSurfaceID: agentFeedNormalizedText(
                wire.surfaceID,
                limitedToUTF8Bytes: mobileShellAgentFeedIdentifierByteLimit
            ),
            workspaceTitle: agentFeedNormalizedText(
                wire.workspaceTitle,
                limitedToUTF8Bytes: mobileShellAgentFeedMetadataByteLimit
            ),
            surfaceTitle: agentFeedNormalizedText(
                wire.surfaceTitle,
                limitedToUTF8Bytes: mobileShellAgentFeedMetadataByteLimit
            ),
            context: context,
            connectionStatus: connectionStatus
        )
    }

    // MARK: - Target resolution
    //
    // These mirror the notification feed's private helpers with the agent
    // feed's capability gate. The state they read (`remoteClient`,
    // `secondaryMacSubscriptions`, pairing identity) is the same.

    private func agentFeedTargets() -> [AgentFeedClientTarget] {
        var targets: [AgentFeedClientTarget] = []
        if let client = remoteClient,
           let macDeviceID = normalizedForegroundNotificationFeedMacIDForEvent(),
           supportedHostCapabilities.contains(Self.agentFeedCapability) {
            targets.append(AgentFeedClientTarget(
                macDeviceID: macDeviceID,
                instanceTag: activeMacInstanceTag,
                displayName: notificationFeedDisplayNameForForeground(macDeviceID: macDeviceID),
                ownerKey: macDeviceID,
                client: client
            ))
        }
        for (ownerKey, subscription) in secondaryMacSubscriptions
        where subscription.client !== remoteClient
            && subscription.supportedHostCapabilities.contains(Self.agentFeedCapability) {
            targets.append(AgentFeedClientTarget(
                macDeviceID: subscription.macDeviceID,
                instanceTag: subscription.storedInstanceTag,
                displayName: notificationFeedDisplayNameForSecondary(
                    macDeviceID: ownerKey.pairingID,
                    fallback: subscription.displayName
                ),
                ownerKey: ownerKey.pairingID,
                client: subscription.client
            ))
        }
        return targets
    }

    private func agentFeedTarget(for macDeviceID: String) -> AgentFeedClientTarget? {
        guard let client = agentFeedClient(for: macDeviceID),
              agentFeedClientSupportsCapability(macDeviceID: macDeviceID) else { return nil }
        return AgentFeedClientTarget(
            macDeviceID: MobilePairedMac.pairingIdentity(from: macDeviceID).macDeviceID,
            instanceTag: agentFeedInstanceTag(forOwnerKey: macDeviceID),
            displayName: notificationFeedDisplayNameForSecondary(
                macDeviceID: macDeviceID,
                fallback: nil
            ),
            ownerKey: macDeviceID,
            client: client
        )
    }

    private func agentFeedInstanceTag(forOwnerKey ownerKey: String) -> String? {
        if normalizedForegroundNotificationFeedMacIDForEvent() == ownerKey {
            return activeMacInstanceTag
        }
        return secondaryMacSubscriptions[MacPairingKey(pairingID: ownerKey)]?.storedInstanceTag
    }

    /// The feed-map key that owns `item`: the foreground key when the item is
    /// the foreground pairing's, else the owning secondary's pairing id.
    /// A tagged item whose exact pairing is offline fails closed on the
    /// pairing key (no client resolves, so mutations no-op).
    private func agentFeedOwnerKey(for item: MobileAgentFeedItem) -> String {
        if let foreground = normalizedForegroundNotificationFeedMacIDForEvent(),
           foreground == item.macDeviceID,
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
        guard item.macInstanceTag == nil else { return pairingKey }
        return item.macDeviceID
    }

    private func agentFeedClient(for macDeviceID: String) -> MobileCoreRPCClient? {
        if normalizedForegroundNotificationFeedMacIDForEvent() == macDeviceID {
            return remoteClient
        }
        guard let subscription =
                secondaryMacSubscriptions[MacPairingKey(pairingID: macDeviceID)],
              !subscription.isTransitioningToFocus else {
            return nil
        }
        return subscription.client
    }

    private func agentFeedClientSupportsCapability(macDeviceID: String) -> Bool {
        if normalizedForegroundNotificationFeedMacIDForEvent() == macDeviceID {
            return supportedHostCapabilities.contains(Self.agentFeedCapability)
        }
        return secondaryMacSubscriptions[MacPairingKey(pairingID: macDeviceID)]?
            .supportedHostCapabilities.contains(Self.agentFeedCapability) == true
    }

    private func agentFeedConnectionStatus(for macDeviceID: String) -> MobileMacConnectionStatus {
        if normalizedForegroundNotificationFeedMacIDForEvent() == macDeviceID {
            return remoteClient == nil ? .unavailable : macConnectionStatus
        }
        if secondaryMacSubscriptions[MacPairingKey(pairingID: macDeviceID)] != nil {
            return .connected
        }
        return workspacesByMac[MacPairingKey(pairingID: macDeviceID)]?.status ?? .unavailable
    }

    private func resolvedAgentFeedStatus() -> MobileNotificationFeedStatus {
        var connectedClientIDs = Set(
            secondaryMacSubscriptions.map { ObjectIdentifier($0.value.client) }
        )
        if let remoteClient {
            connectedClientIDs.insert(ObjectIdentifier(remoteClient))
        }
        guard !connectedClientIDs.isEmpty else { return .unavailable }
        let targets = agentFeedTargets()
        guard !targets.isEmpty else { return .requiresMacUpdate }
        let targetOwnerKeys = Set(targets.map(\.ownerKey))
        if agentFeedItems.isEmpty,
           agentFeedSuccessfulMacIDs.isDisjoint(with: targetOwnerKeys) {
            return .unavailable
        }
        return targets.count < connectedClientIDs.count ? .requiresMacUpdate : .ready
    }

    // MARK: - Normalization

    private func agentFeedNormalizedIdentifier(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.utf8.count <= mobileShellAgentFeedIdentifierByteLimit else {
            return nil
        }
        return trimmed
    }

    private func agentFeedNormalizedText(
        _ value: String?,
        limitedToUTF8Bytes maxBytes: Int
    ) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return agentFeedString(trimmed, limitedToUTF8Bytes: maxBytes)
    }

    private func agentFeedString(
        _ value: String,
        limitedToUTF8Bytes maxBytes: Int
    ) -> String {
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
}
