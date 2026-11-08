import CmuxCloud
import CmuxSurfaceCatalogModel
import Foundation

extension DeviceSurfaceProvider {
    // MARK: Notifications

    /// The other Mac's notification feed runs through the same
    /// ``CloudNotificationSync`` a Cloud machine uses. The hub keys it by the
    /// device's machine raw value, which never collides with a Cloud id.
    func installNotificationSync() {
        let machineID = machine.rawValue
        let hub = CloudNotificationSyncHub.shared
        let sync = CloudNotificationSync(
            machineID: machineID,
            clientID: DeviceNotificationFeed.clientID,
            store: hub.persistenceStore,
            resolveTarget: { [weak self] row in self?.notificationDeliveryTarget(for: row) },
            deliver: { [weak self] row, target in self?.deliverNotification(row, to: target) ?? .declined },
            send: { [weak self] batch in
                // A vanished provider or a dropped link must not report
                // success: the batch stays pending for the next connect.
                guard let self else { throw DeviceLinkError.notConnected }
                do {
                    _ = try await self.link.request("notification.feed.mark_read", params: [
                        "notification_ids": batch.ids,
                    ])
                } catch DeviceLinkError.hostRejected(code: .some("invalid_params"), message: _) {
                    // No id in the batch was a valid UUID: the host will never
                    // accept it, and retrying would block every later read.
                    // Any other rejection (an expired admission) stays pending.
                }
            },
            unreadChanged: { terminalIDs in
                hub.setUnread(terminalIDs, machineID: machineID)
            },
            withdraw: { ids in
                // The other Mac dropped these records from its history.
                guard let store = AppDelegate.shared?.notificationStore else { return }
                let removedIDs = Set(ids)
                for notification in store.notifications where notification.correlationKey.map({ CloudNotificationCorrelation.matches($0, machineID: machineID, notificationIDs: removedIDs) }) == true {
                    store.remove(id: notification.id)
                }
            }
        )
        notificationSync = sync
        hub.register(sync)
        // A row whose terminal is not open here yet is placed once it is.
        notificationPlacementObserver = NotificationCenter.default.addObserver(
            forName: SurfaceCatalog.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let sync = self.notificationSync else { return }
                sync.apply(rows: self.notificationFeed.rows)
            }
        }
    }

    func stopNotificationSync() {
        notificationFeedTask?.cancel()
        notificationFeedTask = nil
        notificationFeedRefetch = false
        CloudNotificationSyncHub.shared.unregister(machineID: machine.rawValue)
        notificationSync?.retire()
        notificationSync = nil
        if let notificationPlacementObserver {
            NotificationCenter.default.removeObserver(notificationPlacementObserver)
            self.notificationPlacementObserver = nil
        }
    }

    /// The link connected or the host announced a feed change. One fetch runs
    /// at a time; changes that arrive meanwhile coalesce into one more.
    func notificationFeedDidChange() {
        guard notificationSync != nil, link.isConnected else { return }
        notificationSync?.linkDidConnect()
        guard notificationFeedTask == nil else {
            notificationFeedRefetch = true
            return
        }
        notificationFeedTask = Task { [weak self] in
            await self?.fetchNotificationFeed()
        }
    }

    private func fetchNotificationFeed() async {
        defer { notificationFeedTask = nil }
        repeat {
            notificationFeedRefetch = false
            let response: [String: Any]
            do {
                response = try await link.request("notification.feed.list")
            } catch {
                // A dropped link reconnects and fetches again; a host that
                // refused the list has nothing this Mac can show, unless a
                // change arrived meanwhile, which earns one more attempt.
                if notificationFeedRefetch, link.isConnected, !Task.isCancelled { continue }
                return
            }
            guard !Task.isCancelled, let notificationSync else { return }
            notificationFeed = DeviceNotificationFeed(response: response)
            notificationSync.apply(rows: notificationFeed.rows)
            #if DEBUG
            cmuxDebugLog("device.notifications.sync machine=\(machine.rawValue) rows=\(notificationFeed.rows.count) unreadTerminals=\(notificationSync.unreadTerminalIDs.count) pending=\(notificationSync.state.pendingAcks.count)")
            #endif
        } while notificationFeedRefetch && !Task.isCancelled
    }

    /// The pane mirroring the terminal when one is open here, else the local
    /// workspace that shows the terminal's remote workspace. Like a Cloud
    /// machine, a row with no local home stays undelivered until one exists.
    func notificationDeliveryTarget(for row: CloudVMNotificationRow) -> CloudNotificationDeliveryTarget? {
        if let terminalID = row.terminalID,
           let projection = catalog.projections(of: SurfaceResourceID(machine: machine, kind: .terminal, key: terminalID)).first {
            return CloudNotificationDeliveryTarget(workspaceID: projection.workspaceID, panelID: projection.panelID)
        }
        let remoteWorkspaceID = row.terminalID.flatMap { terminalWorkspaceIDs[$0.lowercased()] }
            ?? notificationFeed.remoteWorkspaceIDs[row.id]
        guard let remoteWorkspaceID else { return nil }
        return localWorkspaceID(showing: remoteWorkspaceID).map {
            CloudNotificationDeliveryTarget(workspaceID: $0, panelID: nil)
        }
    }

    /// The first local workspace, in sidebar order, holding a pane of a
    /// terminal from the given remote workspace.
    private func localWorkspaceID(showing remoteWorkspaceID: String) -> UUID? {
        let machine = self.machine
        for workspace in AppDelegate.shared?.tabManager?.tabs ?? [] {
            for resource in workspace.cloudBindingState.projectedResources.values
            where resource.machine == machine && resource.kind == .terminal {
                if terminalWorkspaceIDs[resource.key.lowercased()]?.caseInsensitiveCompare(remoteWorkspaceID) == .orderedSame {
                    return workspace.id
                }
            }
        }
        return nil
    }

    func deliverNotification(_ row: CloudVMNotificationRow, to target: CloudNotificationDeliveryTarget) -> CloudNotificationDeliveryOutcome {
        let machineID = machine.rawValue
        return CloudNotificationLocalDelivery(
            machineID: machineID,
            origin: .deviceMac(machineID: machineID),
            store: { AppDelegate.shared?.notificationStore },
            admit: { CloudNotificationSyncHub.shared.admit($0, machineID: machineID) },
            machineName: { [weak self] in self?.record.displayName ?? "" },
            terminalTitle: { [weak self] terminalID in
                self?.link.mirror.workspaces.orderedRecords.lazy
                    .flatMap(\.terminals)
                    .first { $0.id.caseInsensitiveCompare(terminalID) == .orderedSame }?
                    .title
            }
        ).deliver(row, to: target)
    }
}
