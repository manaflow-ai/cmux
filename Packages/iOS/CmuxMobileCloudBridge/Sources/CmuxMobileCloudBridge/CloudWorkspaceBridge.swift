public import CmuxMobileCloud
public import CmuxMobileShell
public import CmuxMobileShellModel
import Foundation

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

    /// Creates a bridge over a source of machine links.
    ///
    /// Production passes the app's ``CloudSessionController``; tests pass a
    /// fake so attachment behavior is exercised without a tunnel.
    public init(links: any CloudMachineLinkProviding) {
        self.links = links
    }

    // MARK: Lifecycle

    /// Starts publishing into `store`.
    public func attach(to store: MobileShellComposite) {
        self.store = store
        store.registerExternalHostSource(self)
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

        for removed in previousIDs.subtracting(nextIDs) {
            retire(machineID: removed)
        }
        for machine in machines {
            publishPlaceholderIfNeeded(machine)
            refreshCatalog(for: machine)
        }
    }

    /// Reloads one machine's workspace and terminal catalog and republishes
    /// its rows.
    public func refreshCatalog(for machine: CloudMachine) {
        catalogTasks[machine.id]?.cancel()
        catalogTasks[machine.id] = Task { [weak self] in
            guard let self else { return }
            guard let connection = links.link(for: machine) else {
                // No tunnel yet. The rows stay published as reconnecting, and
                // the next call (a tunnel-ready change, or a pull to refresh)
                // fills them in.
                publish(machine: machine, workspaces: [], terminals: [], status: .reconnecting, isAuthoritative: false)
                return
            }
            do {
                let (workspaces, terminals) = try await connection.loadCatalog()
                guard !Task.isCancelled else { return }
                publish(
                    machine: machine,
                    workspaces: workspaces,
                    terminals: terminals,
                    status: .connected,
                    isAuthoritative: true
                )
            } catch {
                guard !Task.isCancelled else { return }
                // The catalog read failed: keep the machine visible as
                // unreachable rather than dropping its row, so the user can
                // see it and retry instead of watching it vanish.
                publish(
                    machine: machine,
                    workspaces: [],
                    terminals: [],
                    status: .unavailable,
                    isAuthoritative: false
                )
            }
        }
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

    public func externalHostSendInput(_ text: String, surfaceID: String) {
        guard let address = CloudAddress(parsing: surfaceID),
              let terminalID = address.component,
              let machine = machine(id: address.machineID) else { return }
        // Ensure this surface is the machine's attached terminal before its
        // keystrokes are queued: a keystroke sent while another terminal holds
        // the machine's single attachment would land in the wrong terminal.
        ensureAttached(surfaceID: surfaceID, machine: machine, terminalID: terminalID)
        guard attachedSurfaceIDsByMachine[machine.id] == surfaceID else { return }
        guard let attachment = attachments[machine.id] else {
            // The attach is still in flight. Hold the keystroke rather than
            // dropping it; `ensureAttached` flushes in order once the link is
            // up.
            pendingInputBySurfaceID[surfaceID, default: Data()].append(Data(text.utf8))
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
        guard let connection = links.link(for: machine) else { return }
        teardownAttachment(machineID: machine.id)
        attachedSurfaceIDsByMachine[machine.id] = surfaceID
        attachingSurfaceIDsByMachine[machine.id] = surfaceID

        // The daemon's callback runs on library threads. Yielding into a
        // stream preserves arrival order across that boundary; one consumer
        // then applies the events on the main actor in the same order.
        let (events, continuation) = AsyncStream<CloudTerminalOutputEvent>.makeStream(
            bufferingPolicy: .unbounded
        )
        outputStreams[machine.id] = continuation
        deliveryTasks[machine.id] = Task { @MainActor [weak self] in
            for await event in events {
                self?.deliver(event, surfaceID: surfaceID)
            }
        }

        attachTasks[machine.id] = Task { [weak self] in
            guard let self else { return }
            do {
                let attachment = try await connection.attach(terminalID: terminalID) { event in
                    continuation.yield(event)
                }
                guard !Task.isCancelled else {
                    attachment.detach()
                    continuation.finish()
                    return
                }
                attachments[machine.id] = attachment
                attachingSurfaceIDsByMachine.removeValue(forKey: machine.id)
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
                guard !Task.isCancelled else { return }
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
        attachTasks.removeValue(forKey: machineID)?.cancel()
        attachments.removeValue(forKey: machineID)?.detach()
        outputStreams.removeValue(forKey: machineID)?.finish()
        deliveryTasks.removeValue(forKey: machineID)?.cancel()
        attachingSurfaceIDsByMachine.removeValue(forKey: machineID)
    }

    private func deliver(_ event: CloudTerminalOutputEvent, surfaceID: String) {
        guard let store else { return }
        switch event {
        case .snapshot(let replay, _, _):
            // A snapshot is the daemon's whole screen, so it replaces what is
            // on screen rather than appending to it.
            store.deliverExternalHostTerminalReplay(replay, surfaceID: surfaceID)
        case .output(let bytes):
            store.deliverExternalHostTerminalBytes(bytes, surfaceID: surfaceID)
        case .resized:
            // The phone drives the grid, so a daemon resize needs no local
            // action; the emulator already holds the size it reported.
            break
        case .exited:
            store.deliverExternalHostTerminalBytes(
                Data("\r\n[process exited]\r\n".utf8),
                surfaceID: surfaceID
            )
        }
    }

    // MARK: Publishing

    private func publishPlaceholderIfNeeded(_ machine: CloudMachine) {
        guard let store, catalogTasks[machine.id] == nil else { return }
        store.applyExternalHostWorkspaceState(
            CloudWorkspaceProjector(
                machineID: machine.id,
                displayName: machine.displayName
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
                displayName: machine.displayName
            ).hostState(
                workspaces: workspaces,
                terminals: terminals,
                status: status,
                isAuthoritative: isAuthoritative
            )
        )
    }

    private func retire(machineID: String) {
        catalogTasks.removeValue(forKey: machineID)?.cancel()
        teardownAttachment(machineID: machineID)
        if let surfaceID = attachedSurfaceIDsByMachine.removeValue(forKey: machineID) {
            lastReportedGridBySurfaceID.removeValue(forKey: surfaceID)
            pendingInputBySurfaceID.removeValue(forKey: surfaceID)
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
        catalogTasks = [:]
        attachedSurfaceIDsByMachine = [:]
        lastReportedGridBySurfaceID = [:]
        pendingInputBySurfaceID = [:]
    }

    private func machine(id: String) -> CloudMachine? {
        admittedMachines.first { $0.id == id }
    }
}
