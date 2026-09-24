import CmuxSurfaceCatalogModel
import Foundation

extension CmuxTuiSurfaceProvider {
    // MARK: Notifications
    func installNotificationSync() {
        // The registry never creates a provider while the managed-device
        // policy disables Cloud, so no policy check is repeated here.
        let machineID = self.machineID
        let clientID = CloudTuiClientPaths().notificationClientID()
        let hub = CloudNotificationSyncHub.shared
        let sync = CloudNotificationSync(
            machineID: machineID,
            clientID: clientID, store: hub.persistenceStore,
            resolveTarget: { [weak self] row in self?.notificationDeliveryTarget(for: row) },
            deliver: { [weak self] row, target in self?.deliverNotification(row, to: target) ?? .declined },
            send: { [weak self] batch in
                // A vanished provider must not report success: the batch stays
                // pending in the durable state for the replacement sync.
                guard let self else { throw ProviderError.machineAsleep(machineID) }
                let connected = try await self.links.connected(machineID: machineID)
                guard let link = await self.links.link(machineID: machineID) else {
                    throw ProviderError.machineAsleep(machineID)
                }
                _ = try await link.run(arguments: CloudTuiRequests.notificationAckArguments(
                    socketPath: connected.socketPath,
                    clientID: clientID,
                    notificationIDs: batch.ids,
                    idempotencyKey: batch.key
                ))
            },
            unreadChanged: { terminalIDs in
                hub.setUnread(terminalIDs, machineID: machineID)
            },
            withdraw: { ids in
                // `cmux notify --clear` on the machine, or ledger eviction:
                // the local banners for those rows go with them.
                guard let store = AppDelegate.shared?.notificationStore else { return }
                let removedIDs = Set(ids)
                for notification in store.notifications where notification.correlationKey.map({ CloudNotificationCorrelation.matches($0, machineID: machineID, notificationIDs: removedIDs) }) == true {
                    store.remove(id: notification.id)
                }
            }
        )
        notificationSync = sync
        hub.register(sync)
        notificationPlacementObserver = NotificationCenter.default.addObserver(
            forName: SurfaceCatalog.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let state = self.cloudState else { return }
                self.syncNotifications(from: state)
            }
        }
    }
    func syncNotifications(from state: CloudVMState) {
        updateGuestURLMembership()
        guestURLService?.recoverOnLinkProgress()
        guard let notificationSync else { return }
        let rows = CloudVMNotificationRow.rows(from: state)
        notificationSync.apply(rows: rows)
        #if DEBUG
        cmuxDebugLog("cloud.notifications.sync machine=\(machineID) revision=\((state.cursor?.revision).map(String.init) ?? "nil") rows=\(rows.count) unreadTerminals=\(notificationSync.unreadTerminalIDs.count) pending=\(notificationSync.state.pendingAcks.count)")
        #endif
    }
    /// Placement from the catalog as it is right now; see
    /// `CloudNotificationPlacementResolver`.
    var notificationPlacementResolver: CloudNotificationPlacementResolver {
        CloudNotificationPlacementResolver(
            machine: machine,
            projections: { [catalog] in catalog.projections(of: $0) },
            remoteWorkspaceID: { [weak self] terminalID in
                guard let state = self?.cloudState else { return nil }
                for tab in state.tabs where tab.contentID == terminalID {
                    guard let pane = state.lookupIndex.pane(id: tab.paneID),
                          let screen = state.lookupIndex.screen(id: pane.screenID) else { continue }
                    return screen.workspaceID
                }
                return nil
            },
            boundWorkspaces: { [machineID] in
                (AppDelegate.shared?.tabManager?.tabs ?? []).compactMap { workspace in
                    guard let binding = workspace.cloudVMBinding, binding.vmID == machineID else { return nil }
                    return CloudNotificationBoundWorkspace(workspaceID: workspace.id, remoteWorkspaceID: binding.remoteWorkspaceID)
                }
            }
        )
    }
    func notificationDeliveryTarget(for row: CloudVMNotificationRow) -> CloudNotificationDeliveryTarget? {
        notificationPlacementResolver.target(for: row)
    }
    func deliverNotification(_ row: CloudVMNotificationRow, to target: CloudNotificationDeliveryTarget) -> CloudNotificationDeliveryOutcome {
        let machineID = self.machineID
        return CloudNotificationLocalDelivery(
            machineID: machineID,
            store: { AppDelegate.shared?.notificationStore },
            admit: { CloudNotificationSyncHub.shared.admit($0, machineID: machineID) },
            machineName: { [summary] in summary.preferredName },
            terminalTitle: { [weak self] in self?.cloudState?.lookupIndex.terminal(id: $0)?.title }
        ).deliver(row, to: target)
    }
}
