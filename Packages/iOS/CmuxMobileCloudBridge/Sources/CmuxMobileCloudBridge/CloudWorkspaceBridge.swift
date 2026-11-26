public import CmuxMobileCloud
public import CmuxMobileShell
public import CmuxMobileShellModel
import Foundation
import OSLog

/// Attach and catalog milestones at notice level, so they survive in the
/// persisted log a dogfood report pulls. Ids only; never terminal bytes.
private let bridgeLog = Logger(subsystem: "dev.cmux.ios", category: "cloud-bridge")

/// Publishes the account's Cloud machines into the phone's workspace
/// experience and serves their terminals.
///
/// Every Cloud machine the user has admitted contributes one host entry to the
/// shell store, exactly as a paired Mac does, so its workspaces appear in the
/// workspace list and open into the same detail screen, top toolbar, terminal
/// surface, accessory row and composer. Nothing about that experience is
/// re-implemented here; this type only supplies rows and bytes.
///
/// Attachment is demand-driven and single-slot per machine, matching the
/// daemon's own model: a machine serves one attached terminal at a time, and
/// opening another terminal detaches the previous one. That is the behavior
/// the phone wants anyway, since it shows one terminal at a time.
@MainActor
public final class CloudWorkspaceBridge: MobileExternalHostSource {
    /// Machines this bridge publishes, in list order.
    public private(set) var admittedMachines: [CloudMachine] = []

    private let links: any CloudMachineLinkProviding
    /// Persists which machines the user hid; nil keeps hiding in memory only.
    private let visibility: (any CloudMachineVisibilityStoring)?
    private weak var store: MobileShellComposite?
    private var catalogTasks: [String: Task<Void, Never>] = [:]
    private var attachments: [String: any CloudTerminalLinking] = [:]
    private var attachedSurfaceIDsByMachine: [String: String] = [:]
    private var attachTasks: [String: Task<Void, Never>] = [:]
    private var lastReportedGridBySurfaceID: [String: (columns: Int, rows: Int)] = [:]
    /// The surface each machine is in the middle of attaching, so a repeated
    /// repaint request does not restart an attach that is already running.
    private var attachingSurfaceIDsByMachine: [String: String] = [:]
    /// Ordered hand-off from the library's callback threads to the main actor,
    /// one per machine. Terminal bytes must arrive in the order the daemon
    /// sent them, and an unstructured task per event does not guarantee that.
    private var outputStreams: [String: AsyncStream<CloudTerminalOutputEvent>.Continuation] = [:]
    private var deliveryTasks: [String: Task<Void, Never>] = [:]
    /// Keystrokes typed before a terminal's attachment exists. The view is on
    /// screen and accepting input from the first frame, so without this the
    /// first characters after opening a terminal are lost.
    private var pendingInputBySurfaceID: [String: Data] = [:]
    /// Consecutive failed catalog reads per machine, which pace the retry.
    private var catalogFailureCounts: [String: Int] = [:]
    /// The grid each surface's emulator was last painted for (its snapshot,
    /// or a daemon resize the emulator followed).
    private var appliedGridBySurfaceID: [String: (columns: Int, rows: Int)] = [:]
    /// One pending repaint per machine after the daemon changed the grid.
    private var resizeRepaintTasks: [String: Task<Void, Never>] = [:]
    /// Monotonic attach ownership per machine. A machine has one attachment
    /// slot, and an attach that is no longer the newest must not install its
    /// result or tear down its successor's.
    private var attachGenerationsByMachine: [String: UInt64] = [:]
    /// Each machine's last catalog read, republished with a degraded status
    /// when the link drops or a read fails. Emptying the rows instead would
    /// strand an open terminal: its view resolves its surface through them
    /// before it restarts output.
    private var lastCatalogs: [String: (workspaces: [CloudWorkspaceSummary], terminals: [CloudTerminalSummary])] = [:]
    /// The terminal each machine should be showing, kept through a lost link
    /// so the open terminal re-attaches by itself once the link returns.
    private var wantedSurfaceIDsByMachine: [String: String] = [:]
    private let retryClock: any Clock<Duration>

    /// Creates a bridge over a source of machine links.
    ///
    /// Production passes the app's ``CloudSessionController``; tests pass a
    /// fake so attachment behavior is exercised without a tunnel.
    /// - Parameter retryClock: Paces retries after a failed catalog read;
    ///   tests inject a test clock.
    public init(
        links: any CloudMachineLinkProviding,
        visibility: (any CloudMachineVisibilityStoring)? = nil,
        retryClock: any Clock<Duration> = ContinuousClock()
    ) {
        self.links = links
        self.visibility = visibility
        self.retryClock = retryClock
    }

    /// The wait before retrying a machine whose catalog read failed `failures`
    /// times in a row: 5 s, doubling, capped at a minute. A machine that
    /// cannot be reached keeps being retried at that pace while its tunnel
    /// is up, so a transient control-plane or daemon failure heals on its own.
    static func catalogRetryDelay(afterFailures failures: Int) -> Duration {
        .seconds(min(5 << min(max(failures - 1, 0), 4), 60))
    }

    // MARK: Lifecycle

    /// Starts publishing into `store`.
    ///
    /// The first live store wins. A composition root can build short-lived
    /// stores on re-render (SwiftUI keeps only the first as `@State`), and
    /// re-pointing at one of those would leave the weak reference nil the
    /// moment it deallocates, publishing into nothing.
    public func attach(to store: MobileShellComposite) {
        if let current = self.store {
            guard current === store else { return }
            return
        }
        self.store = store
        store.registerExternalHostSource(self)
    }

    /// Forgets the signed-in account's machines while staying attached, so
    /// signing in again publishes into the same store without a relaunch.
    public func resetForSignOut() {
        setAdmittedMachines([])
        cancelAll()
    }

    /// Stops publishing and removes every row this bridge contributed, so a
    /// sign-out or a disabled Cloud leaves nothing behind.
    public func detachFromStore() {
        guard let store else { return }
        for machine in admittedMachines {
            store.removeExternalHostWorkspaceState(
                macDeviceID: CloudAddress(machineID: machine.id).identifier
            )
        }
        store.unregisterExternalHostSource(self)
        self.store = nil
        cancelAll()
        admittedMachines = []
    }

    /// Sets the machines the user has admitted into their workspace list, and
    /// refreshes each one's catalog.
    ///
    /// A machine dropped from the list has its rows, catalog poll and
    /// attachment torn down in the same pass, so a paused or deleted machine
    /// cannot leave a stale row behind.
    public func setAdmittedMachines(_ machines: [CloudMachine]) {
        let previousIDs = Set(admittedMachines.map(\.id))
        let nextIDs = Set(machines.map(\.id))
        admittedMachines = machines
        applyPersistedVisibility(to: machines)

        for removed in previousIDs.subtracting(nextIDs) {
            retire(machineID: removed)
        }
        for machine in machines {
            // A machine that stopped running (paused, failed) has no daemon to
            // talk to; drop its attachment rather than send into a dead link.
            if !machine.isRunning {
                teardownAttachment(machineID: machine.id)
                attachedSurfaceIDsByMachine.removeValue(forKey: machine.id)
            }
            publishPlaceholderIfNeeded(machine)
            refreshCatalog(for: machine)
        }
    }

    /// Drops every attachment because the tunnel that carried them is gone.
    ///
    /// The session controller closes its machine links when the tunnel stops,
    /// which happens whenever the app goes to the background. The attachments
    /// this bridge holds are then dead: sending into one is silently discarded
    /// rather than failing, so without this the first keystrokes after
    /// returning to a still-open terminal would vanish. Dropping them makes
    /// the next interaction attach again.
    ///
    /// The published rows stay, so the workspace list does not empty out while
    /// the tunnel is down; their liveness is what changes.
    public func linksDidBecomeUnavailable() {
        for (machineID, surfaceID) in attachedSurfaceIDsByMachine {
            wantedSurfaceIDsByMachine[machineID] = surfaceID
        }
        for machineID in Set(attachTasks.keys)
            .union(attachments.keys)
            .union(outputStreams.keys)
            .union(deliveryTasks.keys) {
            teardownAttachment(machineID: machineID)
        }
        attachedSurfaceIDsByMachine = [:]
        pendingInputBySurfaceID = [:]
        // Pending retries would only find no link; the tunnel coming back
        // re-reads every catalog from a fresh start.
        for task in catalogTasks.values { task.cancel() }
        catalogTasks = [:]
        catalogFailureCounts = [:]
        for machine in admittedMachines {
            publishLastCatalog(machine: machine, status: .reconnecting)
        }
    }

    /// Reloads one machine's workspace and terminal catalog and republishes
    /// its rows.
    public func refreshCatalog(for machine: CloudMachine) {
        catalogTasks[machine.id]?.cancel()
        guard machine.isRunning else {
            // Paused, provisioning or failed: there is no daemon to read a
            // catalog from, so publish it unreachable without dialing.
            catalogTasks.removeValue(forKey: machine.id)
            publish(machine: machine, workspaces: [], terminals: [], status: .unavailable, isAuthoritative: true)
            return
        }
        catalogTasks[machine.id] = Task { [weak self] in
            guard let self else { return }
            guard let connection = links.link(for: machine) else {
                // No tunnel yet. The rows stay published as reconnecting, and
                // the next call (a tunnel-ready change, or a pull to refresh)
                // fills them in.
                publishLastCatalog(machine: machine, status: .reconnecting)
                return
            }
            do {
                let catalog = try await connection.loadCatalog()
                guard !Task.isCancelled else { return }
                applyCatalog(catalog, of: machine)
            } catch {
                guard !Task.isCancelled else { return }
                bridgeLog.error("catalog failed machine=\(machine.id, privacy: .public) error=\(String(describing: error), privacy: .public)")
                // The catalog read failed: keep the machine and its last rows
                // visible as unreachable, so the user can see it and retry
                // instead of watching it vanish.
                publishLastCatalog(machine: machine, status: .unavailable)
                let failures = (catalogFailureCounts[machine.id] ?? 0) + 1
                catalogFailureCounts[machine.id] = failures
                do {
                    try await retryClock.sleep(for: Self.catalogRetryDelay(afterFailures: failures))
                } catch {
                    return
                }
                guard !Task.isCancelled,
                      let current = admittedMachines.first(where: { $0.id == machine.id }) else { return }
                refreshCatalog(for: current)
            }
        }
    }

    /// Publishes a catalog read that succeeded.
    private func applyCatalog(
        _ catalog: (workspaces: [CloudWorkspaceSummary], terminals: [CloudTerminalSummary]),
        of machine: CloudMachine
    ) {
        catalogFailureCounts.removeValue(forKey: machine.id)
        bridgeLog.notice("catalog ok machine=\(machine.id, privacy: .public) workspaces=\(catalog.workspaces.count, privacy: .public) terminals=\(catalog.terminals.count, privacy: .public)")
        lastCatalogs[machine.id] = catalog
        publish(
            machine: machine,
            workspaces: catalog.workspaces,
            terminals: catalog.terminals,
            status: .connected,
            isAuthoritative: true
        )
        reattachWantedSurface(of: machine, terminals: catalog.terminals)
    }

    /// Reads `machine`'s catalog now, replacing any read in flight, so a
    /// caller that just changed the daemon finds its change in the rows when
    /// this returns. A failed read hands over to the retrying read.
    private func reloadCatalog(of machine: CloudMachine, over connection: any CloudMachineLinking) async {
        catalogTasks[machine.id]?.cancel()
        catalogTasks.removeValue(forKey: machine.id)
        do {
            let catalog = try await connection.loadCatalog()
            // The machine may have been renamed or retired while this read ran.
            guard let current = admittedMachines.first(where: { $0.id == machine.id }) else { return }
            applyCatalog(catalog, of: current)
        } catch {
            guard let current = admittedMachines.first(where: { $0.id == machine.id }) else { return }
            refreshCatalog(for: current)
        }
    }

    // MARK: Creating

    public func externalHostCreateWorkspace(onHost hostID: String) async -> MobileWorkspacePreview.ID? {
        bridgeLog.notice("create workspace start host=\(hostID, privacy: .public)")
        guard let address = CloudAddress(parsing: hostID), address.component == nil,
              let machine = admittedMachines.first(where: { $0.id == address.machineID }),
              let connection = links.link(for: machine),
              let remoteWorkspaceID = await connection.createWorkspace(name: nil) else {
            bridgeLog.error("create workspace failed host=\(hostID, privacy: .public)")
            return nil
        }
        // Publish the newly-created row as soon as the daemon returns its id.
        // The full catalog read (which supplies the initial terminal) can
        // finish afterward; the shell can select this row immediately instead
        // of waiting for that read to become ready.
        let optimisticWorkspace = CloudWorkspaceSummary(id: remoteWorkspaceID)
        let previous = lastCatalogs[machine.id]
        let optimisticWorkspaces = (previous?.workspaces ?? []).contains(where: { $0.id == remoteWorkspaceID })
            ? (previous?.workspaces ?? [])
            : (previous?.workspaces ?? []) + [optimisticWorkspace]
        lastCatalogs[machine.id] = (
            workspaces: optimisticWorkspaces,
            terminals: previous?.terminals ?? []
        )
        publish(
            machine: machine,
            workspaces: optimisticWorkspaces,
            terminals: previous?.terminals ?? [],
            status: .connected,
            isAuthoritative: false
        )
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.reloadCatalog(of: machine, over: connection)
        }
        return MobileWorkspacePreview.ID(
            rawValue: CloudAddress(machineID: machine.id, component: remoteWorkspaceID).identifier
        )
    }

    public func externalHostCreateTerminal(inWorkspace workspaceID: MobileWorkspacePreview.ID) async -> String? {
        guard let address = CloudAddress(parsing: workspaceID.rawValue),
              let remoteWorkspaceID = address.component,
              let machine = admittedMachines.first(where: { $0.id == address.machineID }) else {
            bridgeLog.error("create terminal skipped: not a Cloud workspace \(workspaceID.rawValue, privacy: .public)")
            return nil
        }
        guard let connection = links.link(for: machine) else {
            bridgeLog.error("create terminal skipped: no link machine=\(machine.id, privacy: .public)")
            return nil
        }
        bridgeLog.notice("create terminal start machine=\(machine.id, privacy: .public) workspace=\(remoteWorkspaceID, privacy: .public)")
        let remoteTerminalID: String?
        if remoteWorkspaceID == CloudWorkspaceProjector.unassignedWorkspaceID {
            // The row gathering terminals no workspace shows is not a daemon
            // workspace, so a terminal made from it gets a workspace of its own.
            if let created = await connection.createWorkspace(name: nil) {
                await reloadCatalog(of: machine, over: connection)
                remoteTerminalID = lastCatalogs[machine.id]?.terminals.first { $0.workspaceID == created }?.id
            } else {
                remoteTerminalID = nil
            }
        } else if let created = await connection.createTerminal(inWorkspace: remoteWorkspaceID, name: nil) {
            await reloadCatalog(of: machine, over: connection)
            remoteTerminalID = created
        } else {
            remoteTerminalID = nil
        }
        guard let remoteTerminalID else {
            bridgeLog.error("create terminal failed workspace=\(workspaceID.rawValue, privacy: .public)")
            return nil
        }
        return CloudAddress(machineID: machine.id, component: remoteTerminalID).identifier
    }

    // MARK: MobileExternalHostSource

    public func externalHostOwnsSurface(_ surfaceID: String) -> Bool {
        guard let address = CloudAddress(parsing: surfaceID), address.component != nil else {
            return false
        }
        return admittedMachines.contains { $0.id == address.machineID }
    }

    public func externalHostOwnsHost(_ hostID: String) -> Bool {
        guard let address = CloudAddress(parsing: hostID), address.component == nil else {
            return false
        }
        return admittedMachines.contains { $0.id == address.machineID }
    }

    public func externalHostReconnect(_ hostID: String) {
        guard let address = CloudAddress(parsing: hostID), address.component == nil,
              let machine = admittedMachines.first(where: { $0.id == address.machineID }) else { return }
        bridgeLog.notice("reconnect machine=\(machine.id, privacy: .public)")
        // Keep the open terminal wanted, so the fresh link repaints it once
        // the catalog read confirms it still exists.
        if let surfaceID = attachedSurfaceIDsByMachine.removeValue(forKey: machine.id) {
            wantedSurfaceIDsByMachine[machine.id] = surfaceID
        }
        teardownAttachment(machineID: machine.id)
        catalogFailureCounts.removeValue(forKey: machine.id)
        links.resetLink(for: machine)
        refreshCatalog(for: machine)
    }

    public func externalHostVisibilityDidChange(_ hostID: String, hidden: Bool) {
        guard let address = CloudAddress(parsing: hostID), address.component == nil else { return }
        visibility?.setMachine(id: address.machineID, hidden: hidden)
    }

    /// Mirrors the persisted hidden set into the store's filter for these
    /// machines. Writes the property directly rather than through
    /// `setExternalHost`, which would echo the change straight back into
    /// persistence and could clear a selection on a launch-time restore.
    private func applyPersistedVisibility(to machines: [CloudMachine]) {
        guard let store, let visibility else { return }
        let persisted = visibility.hiddenMachineIDs
        let hostIDs = Set(machines.map { CloudAddress(machineID: $0.id).identifier })
        let hiddenHosts = Set(
            machines.filter { persisted.contains($0.id) }
                .map { CloudAddress(machineID: $0.id).identifier }
        )
        var next = store.hiddenExternalHostIDs.subtracting(hostIDs)
        next.formUnion(hiddenHosts)
        store.hiddenExternalHostIDs = next
    }

    public func externalHostSendInput(_ text: String, surfaceID: String) {
        guard let address = CloudAddress(parsing: surfaceID),
              let terminalID = address.component,
              let machine = machine(id: address.machineID) else { return }
        // Ensure this surface is the machine's attached terminal before its
        // keystrokes are queued: a keystroke sent while another terminal holds
        // the machine's single attachment would land in the wrong terminal.
        ensureAttached(surfaceID: surfaceID, machine: machine, terminalID: terminalID)
        guard attachedSurfaceIDsByMachine[machine.id] == surfaceID else {
            // No attachment and no link (backgrounding dropped both). The
            // composer accepted the text, so hold a bounded buffer for the
            // surface this machine wants and flush it when the link returns;
            // dropping it here would eat commands typed while the tunnel
            // comes back.
            if wantedSurfaceIDsByMachine[machine.id] == surfaceID,
               (pendingInputBySurfaceID[surfaceID]?.count ?? 0) + text.utf8.count <= Self.pendingInputLimitBytes {
                pendingInputBySurfaceID[surfaceID, default: Data()].append(Data(text.utf8))
                bridgeLog.notice("input held for link return machine=\(machine.id, privacy: .public) bytes=\(text.utf8.count, privacy: .public)")
            }
            return
        }
        guard let attachment = attachments[machine.id] else {
            // The attach is still in flight. Hold the keystroke rather than
            // dropping it; `ensureAttached` flushes in order once the link is
            // up.
            pendingInputBySurfaceID[surfaceID, default: Data()].append(Data(text.utf8))
            bridgeLog.notice("input held until attached machine=\(machine.id, privacy: .public) bytes=\(text.utf8.count, privacy: .public)")
            return
        }
        attachment.send(Data(text.utf8))
    }

    public func externalHostReportViewport(surfaceID: String, columns: Int, rows: Int) {
        guard columns > 0, rows > 0,
              let address = CloudAddress(parsing: surfaceID),
              let machine = machine(id: address.machineID) else { return }
        let previous = lastReportedGridBySurfaceID[surfaceID]
        guard previous?.columns != columns || previous?.rows != rows else { return }
        lastReportedGridBySurfaceID[surfaceID] = (columns, rows)
        // The phone's grid is authoritative for a Cloud terminal: the daemon
        // owns the pseudo-terminal and has no other viewer to reconcile with.
        // A report that arrives before the attachment lands is retained above
        // and replayed by `ensureAttached` once it does.
        guard attachedSurfaceIDsByMachine[machine.id] == surfaceID,
              let attachment = attachments[machine.id] else { return }
        attachment.resize(cols: columns, rows: rows)
    }

    public func externalHostRequestReplay(surfaceID: String) {
        guard let address = CloudAddress(parsing: surfaceID),
              let terminalID = address.component,
              let machine = machine(id: address.machineID) else { return }
        // A replay request is the mount signal. Attaching delivers the
        // daemon's own snapshot, which is a complete screen rather than a
        // byte tail, so re-mounting always repaints correctly.
        ensureAttached(
            surfaceID: surfaceID,
            machine: machine,
            terminalID: terminalID,
            forceReattach: true
        )
    }

    // MARK: Attachment

    private func ensureAttached(
        surfaceID: String,
        machine: CloudMachine,
        terminalID: String,
        forceReattach: Bool = false
    ) {
        if !forceReattach, attachedSurfaceIDsByMachine[machine.id] == surfaceID {
            return
        }
        // A repaint request for the surface already being attached is
        // satisfied by that attach's own snapshot. Restarting would tear the
        // link down and ask for the same screen again, which a view reset or
        // a resync sweep can trigger repeatedly.
        if attachingSurfaceIDsByMachine[machine.id] == surfaceID { return }
        wantedSurfaceIDsByMachine[machine.id] = surfaceID
        guard let connection = links.link(for: machine) else {
            bridgeLog.notice("attach skipped: no link machine=\(machine.id, privacy: .public)")
            return
        }
        // Serialize on the previous attach: its blocking dial cannot be
        // interrupted, and were the new dial to overlap it, the old attach
        // could re-point the machine's single attachment slot after the new
        // one installed itself.
        let previousAttach = attachTasks[machine.id]
        teardownAttachment(machineID: machine.id)
        let generation = (attachGenerationsByMachine[machine.id] ?? 0) &+ 1
        attachGenerationsByMachine[machine.id] = generation
        attachedSurfaceIDsByMachine[machine.id] = surfaceID
        attachingSurfaceIDsByMachine[machine.id] = surfaceID
        bridgeLog.notice("attach start machine=\(machine.id, privacy: .public) terminal=\(terminalID, privacy: .public)")

        // The daemon's callback runs on library threads. Yielding into a
        // stream preserves arrival order across that boundary; one consumer
        // then applies the events on the main actor in the same order.
        let (events, continuation) = AsyncStream<CloudTerminalOutputEvent>.makeStream(
            bufferingPolicy: .unbounded
        )
        outputStreams[machine.id] = continuation
        deliveryTasks[machine.id] = Task { @MainActor [weak self] in
            var delivered = 0
            for await event in events {
                if delivered == 0 {
                    bridgeLog.notice("first output terminal=\(terminalID, privacy: .public) kind=\(event.logKind, privacy: .public)")
                }
                delivered += 1
                self?.deliver(event, surfaceID: surfaceID)
            }
        }

        attachTasks[machine.id] = Task { [weak self] in
            guard let self else { return }
            // The predecessor may be past its cancellation check inside the
            // blocking dial; wait it out so slot ownership transfers in order.
            _ = await previousAttach?.value
            guard attachGenerationsByMachine[machine.id] == generation else {
                continuation.finish()
                return
            }
            do {
                let attachment = try await connection.attach(terminalID: terminalID) { event in
                    continuation.yield(event)
                }
                guard attachGenerationsByMachine[machine.id] == generation, !Task.isCancelled else {
                    // Superseded while dialing: the successor is serialized
                    // behind this task, so the slot is still this attach's to
                    // release, and releasing it cannot touch the successor's.
                    attachment.detach()
                    continuation.finish()
                    return
                }
                attachments[machine.id] = attachment
                attachingSurfaceIDsByMachine.removeValue(forKey: machine.id)
                bridgeLog.notice("attach ok machine=\(machine.id, privacy: .public) terminal=\(terminalID, privacy: .public)")
                // The mounted view reports its grid as soon as it lays out,
                // which is usually before this attachment exists. Replay the
                // last report so the daemon's pseudo-terminal matches the
                // screen instead of keeping the daemon's default size.
                if let grid = lastReportedGridBySurfaceID[surfaceID] {
                    attachment.resize(cols: grid.columns, rows: grid.rows)
                }
                // Then anything typed while the link was coming up, in order.
                if let pending = pendingInputBySurfaceID.removeValue(forKey: surfaceID),
                   !pending.isEmpty {
                    attachment.send(pending)
                }
            } catch {
                continuation.finish()
                guard attachGenerationsByMachine[machine.id] == generation, !Task.isCancelled else { return }
                bridgeLog.error("attach failed machine=\(machine.id, privacy: .public) terminal=\(terminalID, privacy: .public) error=\(String(describing: error), privacy: .public)")
                attachingSurfaceIDsByMachine.removeValue(forKey: machine.id)
                pendingInputBySurfaceID.removeValue(forKey: surfaceID)
                if attachedSurfaceIDsByMachine[machine.id] == surfaceID {
                    attachedSurfaceIDsByMachine.removeValue(forKey: machine.id)
                }
            }
        }
    }

    /// Ends one machine's attachment and its ordered delivery, leaving the
    /// link itself open for the catalog.
    private func teardownAttachment(machineID: String) {
        resizeRepaintTasks.removeValue(forKey: machineID)?.cancel()
        attachTasks.removeValue(forKey: machineID)?.cancel()
        attachments.removeValue(forKey: machineID)?.detach()
        outputStreams.removeValue(forKey: machineID)?.finish()
        deliveryTasks.removeValue(forKey: machineID)?.cancel()
        attachingSurfaceIDsByMachine.removeValue(forKey: machineID)
    }

    private func deliver(_ event: CloudTerminalOutputEvent, surfaceID: String) {
        guard let store else { return }
        switch event {
        case .snapshot(let replay, let cols, let rows):
            // A snapshot is the daemon's whole screen, so it replaces what is
            // on screen rather than appending to it, and it defines the grid
            // everything after it is painted for.
            appliedGridBySurfaceID[surfaceID] = (cols, rows)
            if let machineID = CloudAddress(parsing: surfaceID)?.machineID {
                resizeRepaintTasks.removeValue(forKey: machineID)?.cancel()
            }
            store.deliverExternalHostTerminalReplay(replay, surfaceID: surfaceID)
        case .output(let bytes):
            store.deliverExternalHostTerminalBytes(bytes, surfaceID: surfaceID)
        case .resized(let cols, let rows):
            // The daemon's grid moved away from the one this surface was
            // painted for. That happens when another viewer resizes a shared
            // terminal (a daemon without viewer-size priority takes the
            // smallest grid), and from then on the program repaints only the
            // cells it thinks changed, on a grid the emulator is not at, so
            // stale cells survive on screen. No incremental stream repairs
            // that; only a fresh snapshot does. Repaint after a short settle
            // so a burst of drags costs one repaint.
            guard appliedGridBySurfaceID[surfaceID].map({ $0 != (cols, rows) }) ?? false else { break }
            scheduleResizeRepaint(surfaceID: surfaceID)
        case .exited:
            store.deliverExternalHostTerminalBytes(
                Data("\r\n[process exited]\r\n".utf8),
                surfaceID: surfaceID
            )
        }
    }

    /// The most input held for one surface while its machine's link is away;
    /// enough for typed commands, small enough that a paste flood is refused
    /// rather than replayed as a surprise.
    static let pendingInputLimitBytes = 8 * 1024

    /// The settle before a grid-change repaint, long enough to coalesce a
    /// resize drag, short enough that a corrupted screen barely shows.
    static let resizeRepaintSettle: Duration = .milliseconds(400)

    /// Re-attaches `surfaceID` for a fresh snapshot once the daemon's grid
    /// stops moving. The attach path itself re-reports the phone's grid, so
    /// after the repaint the daemon and the emulator agree again.
    private func scheduleResizeRepaint(surfaceID: String) {
        guard let machineID = CloudAddress(parsing: surfaceID)?.machineID else { return }
        resizeRepaintTasks[machineID]?.cancel()
        resizeRepaintTasks[machineID] = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await retryClock.sleep(for: Self.resizeRepaintSettle)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            resizeRepaintTasks.removeValue(forKey: machineID)
            guard attachedSurfaceIDsByMachine[machineID] == surfaceID,
                  let machine = admittedMachines.first(where: { $0.id == machineID }),
                  let terminalID = CloudAddress(parsing: surfaceID)?.component else { return }
            bridgeLog.notice("grid changed under surface; repainting machine=\(machineID, privacy: .public) terminal=\(terminalID, privacy: .public)")
            ensureAttached(surfaceID: surfaceID, machine: machine, terminalID: terminalID, forceReattach: true)
        }
    }

    // MARK: Publishing

    private func publishPlaceholderIfNeeded(_ machine: CloudMachine) {
        guard let store, catalogTasks[machine.id] == nil else { return }
        if lastCatalogs[machine.id] != nil {
            publishLastCatalog(machine: machine, status: .reconnecting)
            return
        }
        store.applyExternalHostWorkspaceState(
            CloudWorkspaceProjector(
                machineID: machine.id,
                displayName: machine.preferredName
            ).hostState(
                workspaces: [],
                terminals: [],
                status: .reconnecting,
                isAuthoritative: false
            )
        )
    }

    private func publish(
        machine: CloudMachine,
        workspaces: [CloudWorkspaceSummary],
        terminals: [CloudTerminalSummary],
        status: MobileMacConnectionStatus,
        isAuthoritative: Bool
    ) {
        guard let store else { return }
        store.applyExternalHostWorkspaceState(
            CloudWorkspaceProjector(
                machineID: machine.id,
                displayName: machine.preferredName
            ).hostState(
                workspaces: workspaces,
                terminals: terminals,
                status: status,
                isAuthoritative: isAuthoritative
            )
        )
    }

    /// Republishes a machine's last catalog under a degraded status, or an
    /// empty one before its first read.
    private func publishLastCatalog(machine: CloudMachine, status: MobileMacConnectionStatus) {
        let last = lastCatalogs[machine.id]
        publish(
            machine: machine,
            workspaces: last?.workspaces ?? [],
            terminals: last?.terminals ?? [],
            status: status,
            isAuthoritative: false
        )
    }

    /// Re-attaches the terminal a machine was showing when its link dropped,
    /// or that asked to be repainted while it was down, now that a catalog
    /// read proves the link is back. A terminal that no longer exists is
    /// forgotten.
    private func reattachWantedSurface(of machine: CloudMachine, terminals: [CloudTerminalSummary]) {
        guard let surfaceID = wantedSurfaceIDsByMachine[machine.id],
              attachments[machine.id] == nil,
              attachingSurfaceIDsByMachine[machine.id] == nil,
              let terminalID = CloudAddress(parsing: surfaceID)?.component else { return }
        guard terminals.contains(where: { $0.id == terminalID }) else {
            wantedSurfaceIDsByMachine.removeValue(forKey: machine.id)
            return
        }
        ensureAttached(surfaceID: surfaceID, machine: machine, terminalID: terminalID, forceReattach: true)
    }

    private func retire(machineID: String) {
        catalogTasks.removeValue(forKey: machineID)?.cancel()
        catalogFailureCounts.removeValue(forKey: machineID)
        lastCatalogs.removeValue(forKey: machineID)
        wantedSurfaceIDsByMachine.removeValue(forKey: machineID)
        teardownAttachment(machineID: machineID)
        if let surfaceID = attachedSurfaceIDsByMachine.removeValue(forKey: machineID) {
            lastReportedGridBySurfaceID.removeValue(forKey: surfaceID)
            pendingInputBySurfaceID.removeValue(forKey: surfaceID)
            appliedGridBySurfaceID.removeValue(forKey: surfaceID)
        }
        store?.removeExternalHostWorkspaceState(
            macDeviceID: CloudAddress(machineID: machineID).identifier
        )
    }

    private func cancelAll() {
        for task in catalogTasks.values { task.cancel() }
        for machineID in Set(attachTasks.keys)
            .union(attachments.keys)
            .union(outputStreams.keys)
            .union(deliveryTasks.keys) {
            teardownAttachment(machineID: machineID)
        }
        for task in resizeRepaintTasks.values { task.cancel() }
        resizeRepaintTasks = [:]
        appliedGridBySurfaceID = [:]
        catalogTasks = [:]
        catalogFailureCounts = [:]
        lastCatalogs = [:]
        wantedSurfaceIDsByMachine = [:]
        attachedSurfaceIDsByMachine = [:]
        lastReportedGridBySurfaceID = [:]
        pendingInputBySurfaceID = [:]
    }

    private func machine(id: String) -> CloudMachine? {
        admittedMachines.first { $0.id == id }
    }
}

private extension CloudTerminalOutputEvent {
    var logKind: String {
        switch self {
        case .snapshot: "snapshot"
        case .output: "output"
        case .resized: "resized"
        case .exited: "exited"
        }
    }
}
