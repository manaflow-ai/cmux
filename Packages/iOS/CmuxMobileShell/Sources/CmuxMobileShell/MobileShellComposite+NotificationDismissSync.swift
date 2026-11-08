internal import CMUXMobileCore
internal import CmuxMobileDiagnostics
internal import CmuxMobileRPC
import CmuxMobilePairedMac
internal import Foundation
internal import OSLog

private let mobileShellLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "dev.cmux.ios",
    category: "mobile-shell"
)

extension MobileShellComposite {
    /// Enqueue and send phone-side notification dismissals to the owning Mac.
    ///
    /// IDs are stable Mac notification identifiers from `cmux.notificationId`.
    /// They are stored before the RPC and removed only after the Mac confirms,
    /// so a dropped connection flushes them on the next successful subscribe.
    public func dismissNotification(
        ids: [String],
        macDeviceID: String? = nil,
        instanceTag: String? = nil
    ) async {
        let mac = macDeviceID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let tag = instanceTag?.trimmingCharacters(in: .whitespacesAndNewlines)
        await dismissNotifications(
            ids.map {
                PendingNotificationDismiss(
                    id: $0,
                    macDeviceID: mac?.isEmpty == false ? mac : nil,
                    instanceTag: tag?.isEmpty == false ? tag : nil
                )
            },
            enqueueFirst: true
        )
    }

    private func dismissNotifications(
        _ dismisses: [PendingNotificationDismiss],
        enqueueFirst: Bool
    ) async {
        let trimmed = dismisses.compactMap { dismiss -> PendingNotificationDismiss? in
            let id = dismiss.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { return nil }
            let mac = dismiss.macDeviceID?.trimmingCharacters(in: .whitespacesAndNewlines)
            let tag = dismiss.instanceTag?.trimmingCharacters(in: .whitespacesAndNewlines)
            return PendingNotificationDismiss(
                id: id,
                macDeviceID: mac?.isEmpty == false ? mac : nil,
                instanceTag: tag?.isEmpty == false ? tag : nil
            )
        }
        guard !trimmed.isEmpty else { return }
        recordAppEvent(.notificationFeedItemDismissed, count: trimmed.count)
        if enqueueFirst {
            pendingDismissQueue.enqueue(trimmed)
        }
        let groups = Dictionary(grouping: trimmed) { dismiss -> MacPairingKey? in
            dismiss.macDeviceID.map {
                MacPairingKey(macDeviceID: $0, instanceTag: dismiss.instanceTag)
            }
        }
        for (owner, dismisses) in groups {
            await sendNotificationDismisses(dismisses, owner: owner)
        }
    }

    private func sendNotificationDismisses(
        _ dismisses: [PendingNotificationDismiss],
        owner: MacPairingKey?
    ) async {
        let ids = dismisses.map(\.id)
        guard let client = notificationDismissClient(for: owner) else {
            recordAppEvent(
                .notificationFeedItemDismissed,
                correlationID: owner?.pairingID,
                failure: .endpointUnavailable,
                count: ids.count
            )
            return
        }
        do {
            let request = try MobileCoreRPCClient.requestData(
                method: "notification.dismiss",
                params: [
                    "notification_ids": ids,
                    "client_id": clientID,
                ]
            )
            _ = try await client.sendRequest(request)
            pendingDismissQueue.remove(dismisses)
            recordAppEvent(
                .notificationFeedItemDismissed,
                correlationID: owner?.pairingID,
                count: ids.count
            )
        } catch {
            mobileShellLog.error("notification dismiss sync failed count=\(ids.count, privacy: .public) error=\(String(describing: error), privacy: .private)")
            recordAppEvent(
                .notificationFeedItemDismissed,
                correlationID: owner?.pairingID,
                failure: DiagnosticFailureKind.classify(error),
                count: ids.count
            )
        }
    }

    private func notificationDismissClient(for ownerKey: MacPairingKey?) -> MobileCoreRPCClient? {
        guard let ownerKey else { return remoteClient }
        if ownerKey.normalizedInstanceTag != nil {
            if foregroundMacKey == ownerKey { return remoteClient }
            return secondaryMacSubscriptions[ownerKey]?.client
        }
        // Push payloads from older Macs carry only the physical id. Route such
        // a dismissal only when exactly one stored row exists and it is itself
        // untagged. A tagged Stable/Nightly row cannot safely receive a
        // device-only notification because the payload has no build proof.
        let legacyOwnerKey = MacPairingKey(
            macDeviceID: ownerKey.canonicalMacDeviceID,
            instanceTag: nil
        )
        var liveOwners = Set(secondaryMacSubscriptions.keys.filter {
            $0.isOnDevice(ownerKey.canonicalMacDeviceID)
        })
        if foregroundMacKey.isOnDevice(ownerKey.canonicalMacDeviceID), remoteClient != nil {
            liveOwners.insert(foregroundMacKey)
        }
        let storedSiblings = pairedMacsForIdentityMatching.filter {
            cmxCanonicalDeviceID($0.macDeviceID) == ownerKey.canonicalMacDeviceID
        }
        guard storedSiblings.count == 1,
              storedSiblings[0].instanceTag == nil else { return nil }
        guard liveOwners == [legacyOwnerKey] else { return nil }
        if foregroundMacKey == legacyOwnerKey,
           let remoteClient {
            return remoteClient
        }
        return secondaryMacSubscriptions[legacyOwnerKey]?.client
    }

    func flushPendingNotificationDismisses(
        macDeviceID: String? = nil,
        instanceTag: String? = nil
    ) async {
        let requestedOwner = macDeviceID.map {
            MacPairingKey(macDeviceID: $0, instanceTag: instanceTag)
        }
        let pending = pendingDismissQueue.pendingDismisses.filter { dismiss in
            guard let requestedOwner else { return true }
            guard let macDeviceID = dismiss.macDeviceID else { return false }
            return MacPairingKey(
                macDeviceID: macDeviceID,
                instanceTag: dismiss.instanceTag
            ) == requestedOwner
        }
        guard !pending.isEmpty else { return }
        await dismissNotifications(pending, enqueueFirst: false)
    }

    /// Clear delivered iOS banners for Mac notification identifiers.
    ///
    /// Called from live `notification.dismissed` events and foreground reconcile
    /// responses so Mac-side reads/removals clear mirrored phone banners.
    public func clearDeliveredNotifications(
        ids: [String],
        macDeviceID: String? = nil,
        instanceTag: String? = nil
    ) async {
        let trimmed = ids
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !trimmed.isEmpty else { return }
        await deliveredNotificationClearer.removeDelivered(
            ids: trimmed,
            macDeviceID: macDeviceID,
            instanceTag: instanceTag
        )
        recordAppEvent(.notificationFeedItemDismissed, count: trimmed.count)
    }

    /// Set the phone app icon badge to the Mac's authoritative unread total.
    ///
    /// The badge is absolute, not locally incremented/decremented, so drift
    /// self-heals on the next event, push, or reconcile response.
    public func applyAuthoritativeUnreadBadge(_ count: Int) {
        deliveredNotificationClearer.setBadgeCount(max(0, count))
        recordAppEvent(.notificationBadgeReconciled, count: max(0, count))
    }

    func scheduleNotificationReconcile(client: MobileCoreRPCClient) {
        notificationReconcileTask?.cancel()
        notificationReconcileTask = Task { @MainActor [weak self, weak client] in
            guard let self, let client,
                  !Task.isCancelled,
                  self.remoteClient === client,
                  self.connectionState == .connected else { return }
            await self.flushPendingNotificationDismisses()
            guard !Task.isCancelled,
                  self.remoteClient === client,
                  self.connectionState == .connected else { return }
            await self.reconcileNotificationsWithMac(client: client)
        }
    }

    func reconcileNotificationsWithMac(client: MobileCoreRPCClient) async {
        let startedAt = appDiagnosticNow()
        guard let macDeviceID = normalizedForegroundNotificationFeedMacIDForEvent() else {
            return
        }
        let identity = MobilePairedMac.pairingIdentity(from: macDeviceID)
        let deliveredIDs = await deliveredNotificationClearer.deliveredIdentifiers(
            macDeviceID: identity.macDeviceID,
            instanceTag: identity.instanceTag
        )
        guard !Task.isCancelled,
              remoteClient === client,
              connectionState == .connected,
              foregroundMacKey == MacPairingKey(
                macDeviceID: identity.macDeviceID,
                instanceTag: identity.instanceTag
              ) else { return }
        do {
            let request = try MobileCoreRPCClient.requestData(
                method: "notification.reconcile",
                params: [
                    "delivered_ids": deliveredIDs,
                    "client_id": clientID,
                ]
            )
            let data = try await client.sendRequest(request)
            guard remoteClient === client else { return }
            let response = try MobileNotificationReconcileResponse.decode(data)
            await applyNotificationReconcile(
                response,
                macDeviceID: identity.macDeviceID,
                instanceTag: identity.instanceTag
            )
            recordAppEvent(
                .notificationBadgeReconciled,
                startedAt: startedAt,
                count: response.unreadCount
            )
            MobileDebugLog.anchormux(
                "notif.reconcile delivered=\(deliveredIDs.count) handled=\(response.handledIDs.count) unread=\(response.unreadCount.map(String.init) ?? "nil")"
            )
        } catch {
            MobileDebugLog.anchormux("notif.reconcile_failed error=\(error)")
            recordAppEvent(
                .notificationBadgeReconcileFailed,
                startedAt: startedAt,
                failure: DiagnosticFailureKind.classify(error)
            )
        }
    }

    func applyNotificationReconcile(
        _ response: MobileNotificationReconcileResponse,
        macDeviceID: String? = nil,
        instanceTag: String? = nil
    ) async {
        if !response.handledIDs.isEmpty {
            await clearDeliveredNotifications(
                ids: response.handledIDs,
                macDeviceID: macDeviceID,
                instanceTag: instanceTag
            )
        }
        if let unreadCount = response.unreadCount {
            applyAuthoritativeUnreadBadge(unreadCount)
        }
    }
}
