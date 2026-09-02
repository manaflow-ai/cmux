import CmuxSettings
import Foundation
import Network

extension Notification.Name {
    /// Posted by whoever refreshes the machine list (`MachinesPanelViewModel`)
    /// with `userInfo["count"]` = number of machines the account owns, so the
    /// host listener can follow inventory without polling.
    static let cmuxCloudVMInventoryDidChange = Notification.Name("cmux.cloudVM.inventoryDidChange")
    /// Posted by `VMHostListenerCoordinator` after any status change.
    static let cmuxCloudVMHostListenerStatusDidChange = Notification.Name("cmux.cloudVM.hostListenerStatusDidChange")
}

/// Owns the listener Cloud VMs use to reach this Mac, and the four facts that
/// decide whether it exists at all:
///
/// 1. the user turned **Notifications from machines** on (default off),
/// 2. the account is signed in,
/// 3. the WireGuard tunnel into the private Cloud VM network is up, and
/// 4. the account owns at least one machine.
///
/// All four must hold for the listener to be bound. When any one stops
/// holding — the toggle flips, sign-out, the utun disappears, the last
/// machine is destroyed — the listener closes in the same event. No timers:
/// the toggle arrives through `UserDefaults`, sign-out through
/// `.cmuxCloudVMAccessDidEnd`, interface changes through `NWPathMonitor`,
/// and inventory through `.cmuxCloudVMInventoryDidChange` plus machine create
/// completions and link connects.
///
/// The listener binds only the tunnel's own interface addresses, never a
/// wildcard, so nothing on the LAN or loopback can reach it. Each accepted
/// connection is handed to `TerminalController.spawnVMHostClientHandler`,
/// which applies `VMHostAccessPolicy`.
@MainActor
final class VMHostListenerCoordinator {
    static let shared = VMHostListenerCoordinator()

    /// Off-main readable so the socket worker lanes can map tokens to
    /// machines without a main-actor hop.
    nonisolated static let tokens = VMHostTokenStore()

    static let settingsKey = CloudMachinesCatalogSection().hostNotifications.userDefaultsKey
    /// The chosen port is remembered so machines keep a valid endpoint across
    /// relaunches; 0 means "not chosen yet".
    static let portDefaultsKey = "cloud.vmHostNotifications.port"

    struct Status: Sendable, Equatable {
        var enabled = false
        var signedIn = false
        var tunnelUp = false
        var machineCount = 0
        var listening = false
        var port: UInt16 = 0
        var boundAddresses: [String] = []
        var machineFacingAddresses: [String] = []
        var networkCIDRs: [String] = []
        var tokenCount = 0
        /// Whether sign-in and machine inventory have been learned at least
        /// once this session; until then "signed_out" is a guess.
        var inventoryKnown = false
        var lastError: String?
        var offReason: String?
    }

    enum DesiredState: Equatable {
        case on
        case off(reason: String)
    }

    /// The whole lifecycle rule in one testable function.
    nonisolated static func desiredState(
        enabled: Bool,
        signedIn: Bool,
        liveTunnelAddresses: [String],
        machineCount: Int
    ) -> DesiredState {
        guard enabled else { return .off(reason: "disabled") }
        guard signedIn else { return .off(reason: "signed_out") }
        guard !liveTunnelAddresses.isEmpty else { return .off(reason: "tunnel_down") }
        guard machineCount > 0 else { return .off(reason: "no_machines") }
        return .on
    }

    private let manager: VMTunnelManager
    private let defaults: UserDefaults
    private var listener: VMHostListener?
    private var pathMonitor: NWPathMonitor?
    private var observers: [NSObjectProtocol] = []
    private var refreshTask: Task<Void, Never>?
    private var deliveredEndpoints: [String: String] = [:]
    private var linkManagers: [WeakLinkManager] = []
    /// One metadata refresh per tunnel-up episode; reset when the utun goes away.
    private var metadataRefresh: Task<Void, Never>?
    private var metadataRefreshAttempted = false
    private(set) var status = Status()
    private var started = false

    private struct WeakLinkManager {
        weak var value: CloudMachineLinkManager?
    }

    /// Link managers register so a listener that (re)starts can push the new
    /// endpoint to machines that are already connected.
    func register(linkManager: CloudMachineLinkManager) {
        linkManagers.removeAll { $0.value == nil || $0.value === linkManager }
        linkManagers.append(WeakLinkManager(value: linkManager))
    }

    init(manager: VMTunnelManager = VMTunnelManager(), defaults: UserDefaults = .standard) {
        self.manager = manager
        self.defaults = defaults
    }

    // MARK: - lifecycle

    func start() {
        guard !started else { return }
        started = true
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.reconcile(source: "defaults") }
        })
        observers.append(center.addObserver(forName: .cmuxCloudVMAccessDidEnd, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.accessDidEnd() }
        })
        observers.append(center.addObserver(forName: .cmuxCloudVMInventoryDidChange, object: nil, queue: .main) { [weak self] note in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let count = note.userInfo?["count"] as? Int {
                    self.status.signedIn = true
                    self.status.machineCount = count
                    self.reconcile(source: "inventory")
                } else {
                    self.scheduleInventoryRefresh(source: "inventory")
                }
            }
        })
        observers.append(center.addObserver(forName: MachineCreateCoordinator.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.scheduleInventoryRefresh(source: "machineCreate") }
        })
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor [weak self] in self?.reconcile(source: "path") }
        }
        monitor.start(queue: DispatchQueue(label: "dev.cmux.vm-host-listener.path", qos: .utility))
        pathMonitor = monitor
        scheduleInventoryRefresh(source: "start")
    }

    func stop() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        pathMonitor?.cancel()
        pathMonitor = nil
        refreshTask?.cancel()
        stopListener(reason: "stopped")
        started = false
    }

    var isEnabled: Bool {
        defaults.object(forKey: Self.settingsKey) == nil ? false : defaults.bool(forKey: Self.settingsKey)
    }

    func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.settingsKey)
        reconcile(source: "setEnabled")
        // Sign-in and inventory are learned asynchronously; a user who turns
        // the feature on right after launch should not see a stale "not
        // signed in" until some other surface refreshes the machine list.
        if enabled { scheduleInventoryRefresh(source: "setEnabled") }
    }

    /// A link to `machineID` just connected: the account owns at least this
    /// machine, and it is the moment to hand it this Mac's endpoint.
    func machineDidLink(_ machineID: String) async {
        if status.machineCount == 0 {
            status.machineCount = 1
            status.signedIn = true
        }
        reconcile(source: "link")
        await deliverEndpoint(machineID: machineID)
    }

    /// The cmux-tui workspace bound to a Cloud VM changed (`workspace.cloud_vm_bind`):
    /// the machine's env file names that workspace, so redeliver it.
    func bindingDidChange(vmID: String) async {
        deliveredEndpoints[vmID] = nil
        await deliverEndpoint(machineID: vmID)
    }

    /// The Mac workspace a machine's notifications land in: the base cloud
    /// workspace when one is bound, else the first bound workspace.
    func boundWorkspaceID(for machineID: String) -> UUID? {
        let bound = AppDelegate.shared?.workspaces(boundToCloudVM: machineID) ?? []
        return (bound.first { $0.cloudVMBinding?.isBase == true } ?? bound.first)?.id
    }

    /// Write this Mac's endpoint, the machine's token, and the bound workspace
    /// into the machine at `/etc/cmux/host.env`, then register the
    /// `host-forward` journal hook on its daemon. Idempotent per (machine,
    /// payload). Only runs while listening: a machine is never handed an
    /// endpoint that does not exist.
    func deliverEndpoint(machineID: String) async {
        guard status.listening, let endpoint = machineEndpointString() else { return }
        let token = Self.tokens.token(for: machineID)
        let payload = Self.envPayload(
            endpoint: endpoint,
            token: token,
            workspaceID: boundWorkspaceID(for: machineID)?.uuidString
        )
        guard deliveredEndpoints[machineID] != payload else { return }
        guard let client = VMClient.shared else { return }
        let command = Self.deliverCommand(payload: payload)
        do {
            let result = try await client.exec(id: machineID, command: command, timeoutMs: 20_000)
            guard result.exitCode == 0 else {
                status.lastError = "deliver to \(machineID) exited \(result.exitCode): \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
                publish()
                return
            }
            deliveredEndpoints[machineID] = payload
            #if DEBUG
            cmuxDebugLog("vmhost.deliver machine=\(machineID) endpoint=\(endpoint)")
            #endif
        } catch {
            status.lastError = "deliver to \(machineID): \(error.localizedDescription)"
            publish()
            return
        }
        for box in linkManagers {
            guard let manager = box.value else { continue }
            if let failure = await manager.registerHostForwardHook(machineID: machineID) {
                #if DEBUG
                cmuxDebugLog("vmhost.hook machine=\(machineID) failed=\(failure)")
                #endif
                status.lastError = "hook on \(machineID): \(failure)"
                publish()
            }
        }
    }

    /// Tell every machine that was handed an endpoint that it is gone: an env
    /// file with an empty endpoint makes `host-forward` exit without dialing.
    /// Fire-and-forget; a machine that is unreachable simply retries against a
    /// closed port until its own attempts run out.
    private func withdrawEndpoints(from machineIDs: [String]) {
        guard !machineIDs.isEmpty, let client = VMClient.shared else { return }
        let command = Self.deliverCommand(payload: Self.envPayload(endpoint: nil, token: "", workspaceID: nil))
        Task {
            for machineID in machineIDs {
                _ = try? await client.exec(id: machineID, command: command, timeoutMs: 20_000)
            }
        }
    }

    /// The env file body. Keys the guest reads: `CMUX_HOST_ENDPOINT` (empty =
    /// forwarding off), `CMUX_HOST_TOKEN`, `CMUX_HOST_WORKSPACE_ID`.
    nonisolated static func envPayload(endpoint: String?, token: String, workspaceID: String?) -> String {
        "CMUX_HOST_ENDPOINT=\(endpoint ?? "")\nCMUX_HOST_TOKEN=\(token)\nCMUX_HOST_WORKSPACE_ID=\(workspaceID ?? "")\n"
    }

    /// The shell command that installs the env file as root, replacing it
    /// atomically. World-readable on purpose: the daemon drops to the `cmux`
    /// user and runs the hook with an empty environment, so the hook must be
    /// able to open the file itself. Inside the machine every process already
    /// belongs to the owner; the token guards the network, not the guest.
    nonisolated static func deliverCommand(payload: String) -> String {
        let encoded = Data(payload.utf8).base64EncodedString()
        return "sudo -n sh -c 'umask 022; mkdir -p /etc/cmux; printf %s \(encoded) | base64 -d > /etc/cmux/host.env.tmp && chmod 0644 /etc/cmux/host.env.tmp && mv -f /etc/cmux/host.env.tmp /etc/cmux/host.env'"
    }

    /// `host:port` (IPv6 bracketed) machines dial, or nil when the network
    /// metadata is missing or the listener is down.
    func machineEndpointString() -> String? {
        guard status.listening, status.port != 0,
              let address = status.machineFacingAddresses.first else { return nil }
        return address.contains(":") ? "[\(address)]:\(status.port)" : "\(address):\(status.port)"
    }

    /// Network CIDRs a caller must sit inside; read by the connection handler.
    nonisolated static func networkCIDRs(manager: VMTunnelManager = VMTunnelManager()) -> [String] {
        manager.loadNetworkMetadata()?.networkCIDRs ?? []
    }

    func statusPayload() -> [String: Any] {
        let s = status
        return [
            "enabled": s.enabled,
            "signed_in": s.signedIn,
            "tunnel_up": s.tunnelUp,
            "machine_count": s.machineCount,
            "listening": s.listening,
            "port": Int(s.port),
            "bound_addresses": s.boundAddresses,
            "machine_endpoint": machineEndpointString() ?? NSNull(),
            "network_cidrs": s.networkCIDRs,
            "token_count": s.tokenCount,
            "off_reason": s.offReason ?? NSNull(),
            "last_error": s.lastError ?? NSNull(),
            "allowed_methods": VMHostAccessPolicy.allowedMethods.sorted(),
        ]
    }

    // MARK: - internals

    private func accessDidEnd() {
        status.signedIn = false
        status.machineCount = 0
        deliveredEndpoints = [:]
        Self.tokens.removeAll()
        reconcile(source: "accessDidEnd")
    }

    private func scheduleInventoryRefresh(source: String) {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            guard let client = VMClient.shared else {
                self.status.signedIn = false
                self.status.machineCount = 0
                self.status.inventoryKnown = true
                self.reconcile(source: source)
                return
            }
            do {
                let machines = try await client.list()
                guard !Task.isCancelled else { return }
                self.status.signedIn = true
                self.status.inventoryKnown = true
                self.status.lastError = nil
                self.status.machineCount = machines.count
                Self.tokens.retain(vmIDs: Set(machines.map(\.id)))
                let ids = Set(machines.map(\.id))
                self.deliveredEndpoints = self.deliveredEndpoints.filter { ids.contains($0.key) }
            } catch is CancellationError {
                // Superseded by a newer refresh; that one reports.
                return
            } catch let error as VMClientError {
                guard !Task.isCancelled else { return }
                if case .notSignedIn = error {
                    self.status.signedIn = false
                    self.status.machineCount = 0
                    self.status.inventoryKnown = true
                } else {
                    // Backend unreachable or erroring: keep what we knew and
                    // surface the error instead of claiming "signed out".
                    self.status.lastError = error.description
                }
            } catch {
                guard !Task.isCancelled else { return }
                if (error as? URLError)?.code == .cancelled { return }
                self.status.lastError = error.localizedDescription
            }
            self.reconcile(source: source)
        }
    }

    private func reconcile(source: String) {
        let live = manager.liveInterfaceAddresses()
        let metadata = manager.loadNetworkMetadata()
        status.enabled = isEnabled
        status.tunnelUp = !live.isEmpty
        if live.isEmpty { metadataRefreshAttempted = false }
        status.machineFacingAddresses = metadata?.machineFacingAddresses ?? []
        status.networkCIDRs = metadata?.networkCIDRs ?? []
        status.tokenCount = Self.tokens.count

        let desired = Self.desiredState(
            enabled: status.enabled,
            signedIn: status.signedIn,
            liveTunnelAddresses: live,
            machineCount: status.machineCount
        )
        switch desired {
        case .off(var reason):
            if reason == "signed_out", !status.inventoryKnown {
                // Nothing learned yet: either the first fetch is still in
                // flight or it failed. Never claim "signed out" on a guess.
                reason = status.lastError == nil ? "inventory_pending" : "cloud_unreachable"
            }
            stopListener(reason: reason)
        case .on:
            guard !status.machineFacingAddresses.isEmpty, !status.networkCIDRs.isEmpty else {
                stopListener(reason: "network_metadata_missing")
                refreshNetworkMetadataOnce()
                return
            }
            let current = listener?.boundAddresses.map(\.address) ?? []
            if listener?.isListening == true, Set(current) == Set(live) {
                status.offReason = nil
                publish()
                return
            }
            startListener(addresses: live)
        }
        #if DEBUG
        cmuxDebugLog("vmhost.reconcile source=\(source) desired=\(desired) listening=\(status.listening) port=\(status.port)")
        #endif
    }

    /// `network.json` is missing while the tunnel is up: a Mac enrolled before
    /// the file existed. Re-ask the control plane once (idempotent enrollment,
    /// config untouched) and reconcile again when it lands.
    private func refreshNetworkMetadataOnce() {
        guard !metadataRefreshAttempted, metadataRefresh == nil, let client = VMClient.shared else { return }
        metadataRefreshAttempted = true
        metadataRefresh = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.metadataRefresh = nil }
            do {
                _ = try await self.manager.refreshNetworkMetadata(client: client)
                self.reconcile(source: "metadataRefresh")
            } catch {
                self.status.lastError = "network metadata: \(error.localizedDescription)"
                self.publish()
            }
        }
    }

    private func startListener(addresses: [String]) {
        listener?.stop()
        let cidrs = status.networkCIDRs
        let listener = VMHostListener { socket, peer in
            let context = TerminalController.VMHostConnectionContext(peerAddress: peer, networkCIDRs: cidrs)
            Task { @MainActor in
                await TerminalController.shared.spawnVMHostClientHandler(socket: socket, context: context)
            }
        }
        let remembered = UInt16(clamping: defaults.integer(forKey: Self.portDefaultsKey))
        do {
            do {
                try listener.start(addresses: addresses, port: remembered)
            } catch where remembered != 0 {
                // The remembered port is taken; pick a fresh one and remember it.
                try listener.start(addresses: addresses, port: 0)
            }
            self.listener = listener
            let port = listener.boundAddresses.first?.port ?? 0
            if port != remembered { defaults.set(Int(port), forKey: Self.portDefaultsKey) }
            status.listening = true
            status.port = port
            status.boundAddresses = listener.boundAddresses.map(\.address)
            status.offReason = nil
            status.lastError = nil
            publish()
            // Machines already linked need the (possibly new) endpoint.
            deliveredEndpoints = [:]
            for box in linkManagers {
                guard let manager = box.value else { continue }
                Task { await manager.redeliverHostEndpoints() }
            }
            linkManagers.removeAll { $0.value == nil }
        } catch {
            self.listener = nil
            status.listening = false
            status.port = 0
            status.boundAddresses = []
            status.lastError = "listener: \(error)"
            status.offReason = "bind_failed"
            publish()
        }
    }

    private func stopListener(reason: String) {
        let wasListening = status.listening
        if wasListening { withdrawEndpoints(from: Array(deliveredEndpoints.keys)) }
        listener?.stop()
        listener = nil
        status.listening = false
        status.port = 0
        status.boundAddresses = []
        status.offReason = reason
        deliveredEndpoints = [:]
        if wasListening || status.offReason != reason { publish() }
    }

    private func publish() {
        NotificationCenter.default.post(name: .cmuxCloudVMHostListenerStatusDidChange, object: self)
    }
}
