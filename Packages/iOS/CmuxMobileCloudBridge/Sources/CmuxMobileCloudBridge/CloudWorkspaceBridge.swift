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

    private let controller: CloudSessionController
    private weak var store: MobileShellComposite?
    private var catalogTasks: [String: Task<Void, Never>] = [:]
    private var attachments: [String: CloudTerminalAttachment] = [:]
    private var attachedSurfaceIDsByMachine: [String: String] = [:]
    private var attachTasks: [String: Task<Void, Never>] = [:]
    private var lastReportedGridBySurfaceID: [String: (columns: Int, rows: Int)] = [:]

    /// Creates a bridge over the Cloud session controller.
    public init(controller: CloudSessionController) {
        self.controller = controller
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
                macDeviceID: CloudSurfaceIdentity.hostID(machineID: machine.id)
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
            guard let connection = controller.connection(for: machine) else {
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
        guard let parsed = CloudSurfaceIdentity.parse(surfaceID) else { return false }
        return admittedMachines.contains { $0.id == parsed.machineID }
    }

    public func externalHostOwnsHost(_ hostID: String) -> Bool {
        guard let machineID = CloudSurfaceIdentity.machineID(fromHostID: hostID) else { return false }
        return admittedMachines.contains { $0.id == machineID }
    }

    public func externalHostSendInput(_ text: String, surfaceID: String) {
        guard let parsed = CloudSurfaceIdentity.parse(surfaceID),
              let machine = machine(id: parsed.machineID) else { return }
        // Ensure this surface is the machine's attached terminal before its
        // keystrokes are queued: a keystroke sent while another terminal holds
        // the machine's single attachment would land in the wrong terminal.
        ensureAttached(surfaceID: surfaceID, machine: machine, terminalID: parsed.remainder)
        guard attachedSurfaceIDsByMachine[machine.id] == surfaceID,
              let attachment = attachments[machine.id] else { return }
        attachment.send(Data(text.utf8))
    }

    public func externalHostReportViewport(surfaceID: String, columns: Int, rows: Int) {
        guard columns > 0, rows > 0,
              let parsed = CloudSurfaceIdentity.parse(surfaceID),
              let machine = machine(id: parsed.machineID) else { return }
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
        guard let parsed = CloudSurfaceIdentity.parse(surfaceID),
              let machine = machine(id: parsed.machineID) else { return }
        // A replay request is the mount signal. Attaching delivers the
        // daemon's own snapshot, which is a complete screen rather than a
        // byte tail, so re-mounting always repaints correctly.
        ensureAttached(
            surfaceID: surfaceID,
            machine: machine,
            terminalID: parsed.remainder,
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
        guard let connection = controller.connection(for: machine) else { return }
        attachTasks[machine.id]?.cancel()
        if let existing = attachments.removeValue(forKey: machine.id) {
            existing.detach()
        }
        attachedSurfaceIDsByMachine[machine.id] = surfaceID
        attachTasks[machine.id] = Task { [weak self] in
            guard let self else { return }
            do {
                let attachment = try await connection.attach(terminalID: terminalID) { event in
                    Task { @MainActor [weak self] in
                        self?.deliver(event, surfaceID: surfaceID)
                    }
                }
                guard !Task.isCancelled else {
                    attachment.detach()
                    return
                }
                attachments[machine.id] = attachment
                // The mounted view reports its grid as soon as it lays out,
                // which is usually before this attachment exists. Replay the
                // last report so the daemon's pseudo-terminal matches the
                // screen instead of keeping the daemon's default size.
                if let grid = lastReportedGridBySurfaceID[surfaceID] {
                    attachment.resize(cols: grid.columns, rows: grid.rows)
                }
            } catch {
                guard !Task.isCancelled else { return }
                if attachedSurfaceIDsByMachine[machine.id] == surfaceID {
                    attachedSurfaceIDsByMachine.removeValue(forKey: machine.id)
                }
            }
        }
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
            CloudWorkspaceProjection.hostState(
                machineID: machine.id,
                displayName: machine.displayName,
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
            CloudWorkspaceProjection.hostState(
                machineID: machine.id,
                displayName: machine.displayName,
                workspaces: workspaces,
                terminals: terminals,
                status: status,
                isAuthoritative: isAuthoritative
            )
        )
    }

    private func retire(machineID: String) {
        catalogTasks.removeValue(forKey: machineID)?.cancel()
        attachTasks.removeValue(forKey: machineID)?.cancel()
        attachments.removeValue(forKey: machineID)?.detach()
        if let surfaceID = attachedSurfaceIDsByMachine.removeValue(forKey: machineID) {
            lastReportedGridBySurfaceID.removeValue(forKey: surfaceID)
        }
        store?.removeExternalHostWorkspaceState(
            macDeviceID: CloudSurfaceIdentity.hostID(machineID: machineID)
        )
    }

    private func cancelAll() {
        for task in catalogTasks.values { task.cancel() }
        for task in attachTasks.values { task.cancel() }
        for attachment in attachments.values { attachment.detach() }
        catalogTasks = [:]
        attachTasks = [:]
        attachments = [:]
        attachedSurfaceIDsByMachine = [:]
        lastReportedGridBySurfaceID = [:]
    }

    private func machine(id: String) -> CloudMachine? {
        admittedMachines.first { $0.id == id }
    }
}
