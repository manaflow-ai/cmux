import CmuxCloud
import CmuxCloudTui
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
        hub.register(sync, remoteWorkspaceID: { [weak self] terminalID in
            guard let state = self?.cloudState else { return [] }
            var workspaceIDs = Set<String>()
            for tab in state.tabs where tab.contentID.caseInsensitiveCompare(terminalID) == .orderedSame {
                guard let pane = state.lookupIndex.pane(id: tab.paneID),
                      let screen = state.lookupIndex.screen(id: pane.screenID) else { continue }
                workspaceIDs.insert(screen.workspaceID)
            }
            return workspaceIDs
        })
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
        syncAgentHooks(from: state)
        updateGuestURLMembership()
        guestURLService?.recoverOnLinkProgress()
        guard let notificationSync else { return }
        let rows = CloudVMNotificationRow.rows(from: state)
        notificationSync.apply(rows: rows)
        #if DEBUG
        cmuxDebugLog("cloud.notifications.sync machine=\(machineID) revision=\((state.cursor?.revision).map(String.init) ?? "nil") rows=\(rows.count) unreadTerminals=\(notificationSync.unreadTerminalIDs.count) pending=\(notificationSync.state.pendingAcks.count)")
        #endif
    }
    // MARK: Agent hooks
    /// Replays the session identity of Claude agents in `cmux ssh` panes into
    /// the local hook queue, so the Mac's hook pipeline knows the remote
    /// agent's session. Runs with every accepted state and every catalog
    /// change, so a session whose pane was not open yet is caught up when it
    /// opens. Sidebar status comes from the roster projection, and visible
    /// notifications from the daemon's durable rows (`syncNotifications`).
    func syncAgentHooks(from state: CloudVMState) {
        guard machine.isSSH else { return }
        let machine = self.machine
        let catalog = self.catalog
        func panel(for terminalID: String) -> SurfaceProjection? {
            catalog.projections(of: SurfaceResourceID(machine: machine, kind: .terminal, key: terminalID)).first
        }
        let routable = Set(state.agents.map(\.terminalID).filter { panel(for: $0) != nil })
        let events = agentHookMirror.reconcile(agents: state.agents, routableTerminalIDs: routable)
        guard !events.isEmpty else { return }
        let controller = TerminalController.shared
        for event in events {
            // A session end for a terminal whose pane already closed has no
            // local state left to clear.
            guard let projection = panel(for: event.terminalID) else { continue }
            let queued = controller.enqueueMirroredAgentHook(
                agent: event.agent,
                subcommand: event.subcommand,
                payload: event.payload,
                workspaceID: projection.workspaceID,
                surfaceID: projection.panelID
            )
            #if DEBUG
            cmuxDebugLog("cloud.agentHook.mirror machine=\(machineID) terminal=\(event.terminalID) subcommand=\(event.subcommand) queued=\(queued)")
            #else
            _ = queued
            #endif
        }
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
            origin: .cloudVM(machineID: machineID),
            store: { AppDelegate.shared?.notificationStore },
            admit: { CloudNotificationSyncHub.shared.admit($0, machineID: machineID) },
            machineName: { [summary] in summary.preferredName },
            terminalTitle: { [weak self] in self?.cloudState?.lookupIndex.terminal(id: $0)?.title }
        ).deliver(row, to: target)
    }
}
