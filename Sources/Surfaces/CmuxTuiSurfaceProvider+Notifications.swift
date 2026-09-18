import Foundation

extension CmuxTuiSurfaceProvider {
    // MARK: Notifications
    func installNotificationSync() {
        // The registry never creates a provider while the managed-device
        // policy disables Cloud, so no policy check is repeated here.
        let machineID = self.machineID
        let clientID = CloudTuiClientPaths().notificationClientID()
        let sync = CloudNotificationSync(
            machineID: machineID,
            clientID: clientID, store: CloudNotificationSyncHub.shared.persistenceStore,
            resolveTarget: { [weak self] row in self?.notificationDeliveryTarget(for: row) },
            deliver: { [weak self] row, target in self?.deliverNotification(row, to: target) ?? false },
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
                CloudNotificationSyncHub.shared.setUnread(terminalIDs, machineID: machineID)
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
        CloudNotificationSyncHub.shared.register(sync)
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
    /// The pane showing the terminal when one is open on this Mac, else the
    /// local workspace bound to the terminal's remote workspace, else any
    /// local workspace bound to the machine. No local placement means the row
    /// stays undelivered until one exists; the Cloud tree still shows the dot.
    func notificationDeliveryTarget(for row: CloudVMNotificationRow) -> CloudNotificationDeliveryTarget? {
        if let terminalID = row.terminalID {
            let resourceID = SurfaceResourceID(machine: machine, kind: .terminal, key: terminalID)
            if let projection = catalog.projections(of: resourceID).first {
                return CloudNotificationDeliveryTarget(workspaceID: projection.workspaceID, panelID: projection.panelID)
            }
        }
        let remoteWorkspaceID = row.terminalID.flatMap { terminalID -> String? in
            guard let state = cloudState else { return nil }
            for tab in state.tabs where tab.contentID == terminalID {
                guard let pane = state.lookupIndex.pane(id: tab.paneID),
                      let screen = state.lookupIndex.screen(id: pane.screenID) else { continue }
                return screen.workspaceID
            }
            return nil
        }
        let bound = (AppDelegate.shared?.tabManager?.tabs ?? []).filter { $0.cloudVMBinding?.vmID == machineID }
        if let remoteWorkspaceID,
           let exact = bound.first(where: { $0.cloudVMBinding?.remoteWorkspaceID == remoteWorkspaceID }) {
            return CloudNotificationDeliveryTarget(workspaceID: exact.id, panelID: nil)
        }
        if let any = bound.first {
            return CloudNotificationDeliveryTarget(workspaceID: any.id, panelID: nil)
        }
        return nil
    }
    func deliverNotification(_ row: CloudVMNotificationRow, to target: CloudNotificationDeliveryTarget) -> Bool {
        guard let store = AppDelegate.shared?.notificationStore else { return false }
        guard CloudNotificationSyncHub.shared.admit(row, machineID: machineID) else { return true }
        let terminalTitle = row.terminalID.flatMap { cloudState?.lookupIndex.terminal(id: $0)?.title } ?? ""
        let machineName = summary.preferredName
        let subtitle: String
        if let explicit = row.subtitle {
            // The producer's own subtitle wins, as `cmux notify --subtitle` does locally.
            subtitle = explicit
        } else if terminalTitle.isEmpty {
            subtitle = machineName
        } else {
            subtitle = String(
                format: String(localized: "cloudNotification.subtitle.machine", defaultValue: "%@ on %@"),
                terminalTitle,
                machineName
            )
        }
        return store.addNotification(
            tabId: target.workspaceID,
            surfaceId: target.panelID,
            title: row.title,
            subtitle: subtitle,
            body: row.body,
            retargetsToLiveSurfaceOwner: target.panelID != nil,
            correlationKey: CloudNotificationCorrelation.key(machineID: machineID, notificationID: row.id),
            origin: .cloudVM(machineID: machineID)
        ) != nil
    }
}
