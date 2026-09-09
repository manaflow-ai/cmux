import CmuxFoundation
import Foundation

/// The app's headless cmux-tui links, one per awake cloud machine. Links are created on
/// demand (a tree read, a terminal open) — never to list a sleeping machine, since the
/// control plane wakes a machine on attach — and torn down when the machine is deleted
/// or the account signs out.
///
/// The private route comes from the machine list. For a device this machine
/// has not seen, the control plane proves the machine's trusted listener first.
/// Later links use only the saved device key and private route.
actor CloudMachineLinkManager {
    struct LinkStatus: Sendable, Equatable {
        let state: SurfaceLinkState
        let error: String?
    }

    enum ManagerError: Error, LocalizedError {
        case clientMissing
        case wireGuardHubMissing
        case wireGuardHubUnsupported
        case privateRouteRequired(String)
        case retryLater(String)

        var errorDescription: String? {
            switch self {
            case .clientMissing:
                return "No cmux-tui client is bundled with this build (Contents/Resources/bin/cmux-tui) and CMUX_TUI_CLIENT is unset."
            case .wireGuardHubMissing:
                return "The cmux user-space WireGuard hub is not available in this build."
            case .wireGuardHubUnsupported:
                return "The bundled cmux-tui client does not support the user-space WireGuard hub."
            case .privateRouteRequired(let route):
                return "The Cloud machine did not provide a private-network route: \(route)"
            case .retryLater(let detail):
                return detail
            }
        }
    }

    private let paths: CloudTuiClientPaths
    private let clientURL: URL?
    /// The app's in-process WireGuard hub; nil in tests that never touch the network.
    /// A machine whose route points into the private network is linked through it when
    /// the bundled client advertises `wireguard-hub`. Public routes are refused.
    private let hub: CloudWireGuardHub?
    /// Private routes come from the signed-in machine list. An enrolled client
    /// reconnects with this local fact and does not call the attach endpoint.
    private var privateRoutes: [String: String] = [:]
    private var links: [String: CloudMachineLink] = [:]
    private var connecting: [String: Task<CloudMachineLink.Connected, Error>] = [:]
    private var lastFailure: [String: (at: Date, error: String)] = [:]
    /// A failed link is not retried for this long, so a polling sidebar does not hammer
    /// a machine whose route is broken.
    private let retryBackoff: TimeInterval = 15
    /// How long a link may take to report its socket: the daemon accepts a
    /// carrier or enrolled session immediately, so anything slower than this is
    /// a broken route rather than a slow one.
    private let connectTimeout: Duration = .seconds(60)
    /// This Mac's resolved Ghostty default colors ("#rrggbb"), pushed to each machine as
    /// its cmux-tui session defaults (`set-default-colors`) so remote panes render with
    /// the local theme. Injected so tests need no Ghostty runtime.
    private let hostThemeColors: @Sendable () async -> (foreground: String, background: String)?
    /// Theme-push coalescing: at most ONE in-flight push and ONE queued rerun per
    /// machine. A reload burst collapses to a single trailing push that reads the
    /// colors when it runs, so the machine always ends on the latest theme and the
    /// link never accumulates a backlog of defaults commands.
    private var themePushInFlight: Set<String> = []
    private var themePushQueued: Set<String> = []

    init(
        paths: CloudTuiClientPaths = CloudTuiClientPaths(),
        clientURL: URL? = CloudTuiClientPaths.clientURL(),
        hub: CloudWireGuardHub? = nil,
        hostThemeColors: @escaping @Sendable () async -> (foreground: String, background: String)? = {
            await MainActor.run {
                let app = GhosttyApp.shared
                return (app.defaultForegroundColor.hexString(), app.defaultBackgroundColor.hexString())
            }
        }
    ) {
        self.paths = paths
        self.clientURL = clientURL
        self.hub = hub
        self.hostThemeColors = hostThemeColors
    }

    /// Whether a link to `route` goes through the WireGuard hub: the client must know
    /// the flag and the route's host must be a literal address inside the private
    /// network (the hub's enrolled routes when known, else the private ranges).
    nonisolated static func usesWireGuardHub(route: String, clientCapabilities: [String], enrolledRoutes: [String]) -> Bool {
        guard clientCapabilities.contains(CloudTuiCommandLine.wireGuardHubCapability),
              let host = IPNetworkPrefix.routeHost(route) else { return false }
        return CloudWireGuardHub.routesHost(host, enrolledRoutes: enrolledRoutes)
    }

    var hasClient: Bool { clientURL != nil }

    func setPrivateAddress(_ address: String?, for machineID: String) {
        guard let address = address?.trimmingCharacters(in: .whitespacesAndNewlines), !address.isEmpty else {
            privateRoutes[machineID] = nil
            return
        }
        let host = address.contains(":") ? "[\(address)]" : address
        privateRoutes[machineID] = "ws://\(host):1337/v1/link"
    }

    func privateRoute(for machineID: String) -> String? {
        privateRoutes[machineID]
    }

    /// The link for `machineID`, connecting (and enrolling) if needed.
    func connected(machineID: String) async throws -> CloudMachineLink.Connected {
        if let link = links[machineID], await link.isConnected, let connected = await link.connected {
            return connected
        }
        if let inFlight = connecting[machineID] {
            return try await inFlight.value
        }
        if let failure = lastFailure[machineID], Date().timeIntervalSince(failure.at) < retryBackoff {
            throw ManagerError.retryLater(failure.error)
        }
        guard let clientURL else { throw ManagerError.clientMissing }
        guard let privateRoute = privateRoutes[machineID] else {
            throw ManagerError.privateRouteRequired(machineID)
        }
        #if DEBUG
        cmuxDebugLog("cloud.link.connect machine=\(machineID)")
        #endif
        let task = Task<CloudMachineLink.Connected, Error> { [paths, hub] in
            let link = CloudMachineLink(machineID: machineID, clientURL: clientURL, paths: paths)
            self.store(link: link, for: machineID)
            let capabilities = Self.clientCapabilities(clientURL: clientURL)
            let knownFingerprint = paths.deviceFingerprint(for: machineID)
            var session = "cmux"
            // The machine's daemon serves a trusted listener inside the private
            // network, so a link needs no enrollment: the first use asks the
            // control plane once (it also brings an older daemon to the trusted
            // build), later uses dial `--carrier` from the stored marker with no
            // control-plane call. A real stored fingerprint is a machine this Mac
            // enrolled with before trusted listeners; it keeps its stored key.
            let carrier: Bool
            if let knownFingerprint {
                carrier = knownFingerprint == CloudTuiClientPaths.carrierDeviceMarker
            } else {
                let client = await MainActor.run { VMClient.shared }
                guard let client else {
                    throw VMClientError.malformedResponse("Cloud VM client is not available (not signed in).")
                }
                let endpoint = try await client.openCmuxRemote(
                    id: machineID,
                    deviceFingerprint: nil,
                    clientCapabilities: capabilities
                )
                session = endpoint.session
                guard endpoint.trustedCarrier else {
                    throw ManagerError.retryLater(String(
                        localized: "cloud.link.trustedListenerPending",
                        defaultValue: "The Cloud machine is still preparing remote access. Try again shortly."
                    ))
                }
                carrier = true
            }
            guard capabilities.contains(CloudTuiCommandLine.wireGuardHubCapability) else {
                throw ManagerError.wireGuardHubUnsupported
            }
            guard Self.usesWireGuardHub(route: privateRoute, clientCapabilities: capabilities, enrolledRoutes: []) else {
                throw ManagerError.privateRouteRequired(privateRoute)
            }
            guard let hub else { throw ManagerError.wireGuardHubMissing }
            let claim = try await hub.acquire()
            guard Self.usesWireGuardHub(
                route: privateRoute,
                clientCapabilities: capabilities,
                enrolledRoutes: claim.ready.routes
            ) else {
                await hub.release(claim.lease)
                throw ManagerError.privateRouteRequired(privateRoute)
            }
            let releaseLease: @Sendable () async -> Void = { await hub.release(claim.lease) }
            #if DEBUG
            cmuxDebugLog("cloud.link.wireguardHub machine=\(machineID) socket=\(claim.ready.socketPath)")
            #endif
            let connect = Task {
                try await link.connect(
                    route: privateRoute,
                    session: session,
                    carrier: carrier,
                    timeout: connectTimeout,
                    wireguardHubSocket: claim.ready.socketPath,
                    releaseHubLease: releaseLease
                )
            }
            do {
                let connected = try await connect.value
                if carrier, knownFingerprint == nil {
                    paths.saveDeviceFingerprint(CloudTuiClientPaths.carrierDeviceMarker, for: machineID)
                }
                return connected
            } catch {
                connect.cancel()
                await link.disconnect()
                throw error
            }
        }
        connecting[machineID] = task
        defer { connecting[machineID] = nil }
        do {
            let connected = try await task.value
            lastFailure[machineID] = nil
            #if DEBUG
            cmuxDebugLog("cloud.link.connected machine=\(machineID) socket=\(connected.socketPath)")
            #endif
            pushHostTheme(machineID: machineID, socketPath: connected.socketPath)
            return connected
        } catch {
            let text = CloudMachineLink.errorText(error)
            lastFailure[machineID] = (Date(), text)
            links[machineID] = nil
            #if DEBUG
            cmuxDebugLog("cloud.link.failed machine=\(machineID) error=\(String(reflecting: error)) text=\(text)")
            #endif
            throw error
        }
    }

    func link(machineID: String) -> CloudMachineLink? {
        links[machineID]
    }

    /// Machines with a live link right now: the app-side consumers of the
    /// private network for the tunnel's idle policy.
    var connectedMachineCount: Int {
        get async {
            var machineIDs = Set(connecting.keys)
            for link in links.values {
                guard await link.isConnected else { continue }
                machineIDs.insert(link.machineID)
            }
            return machineIDs.count
        }
    }

    func status(machineID: String) async -> LinkStatus? {
        if let link = links[machineID] {
            return LinkStatus(state: await link.state, error: await link.lastError)
        }
        if connecting[machineID] != nil {
            return LinkStatus(state: .connecting, error: nil)
        }
        if let failure = lastFailure[machineID], Date().timeIntervalSince(failure.at) < retryBackoff {
            return LinkStatus(state: .error, error: failure.error)
        }
        return nil
    }

    func disconnect(machineID: String) async {
        connecting[machineID]?.cancel()
        connecting[machineID] = nil
        // An in-flight drain notices the removed link on its next run; dropping the
        // queued mark keeps it from issuing one more command to a machine being cut.
        themePushQueued.remove(machineID)
        if let link = links.removeValue(forKey: machineID) {
            await link.disconnect()
        }
        lastFailure[machineID] = nil
    }

    func disconnectAll() async {
        for id in Array(links.keys) {
            await disconnect(machineID: id)
        }
        for task in connecting.values { task.cancel() }
        connecting.removeAll()
        lastFailure.removeAll()
    }

    /// Drops links for machines that no longer exist.
    func retain(machineIDs: Set<String>) async {
        for id in links.keys where !machineIDs.contains(id) {
            await disconnect(machineID: id)
        }
        privateRoutes = privateRoutes.filter { machineIDs.contains($0.key) }
    }

    /// Re-sends this Mac's theme to every connected machine (a Ghostty config reload
    /// changed the resolved colors). Live attach panes repaint via `colors-changed`.
    func pushHostThemeToConnectedLinks() async {
        for (machineID, link) in links {
            guard await link.isConnected, let connected = await link.connected else { continue }
            pushHostTheme(machineID: machineID, socketPath: connected.socketPath)
        }
    }

    // MARK: - internals

    /// Fire-and-forget: theme parity is cosmetic, so a machine that predates
    /// the defaults verb (or a link that just dropped) must not fail the operation
    /// that connected it. While a push is in flight, further requests only mark a
    /// rerun; the trailing run reads the colors when it starts, so a reload burst
    /// costs at most one extra command and always lands on the latest theme.
    private func pushHostTheme(machineID: String, socketPath: String) {
        guard links[machineID] != nil else { return }
        guard !themePushInFlight.contains(machineID) else {
            themePushQueued.insert(machineID)
            return
        }
        themePushInFlight.insert(machineID)
        Task { await self.drainThemePushes(machineID: machineID, socketPath: socketPath) }
    }

    private func drainThemePushes(machineID: String, socketPath: String) async {
        repeat {
            themePushQueued.remove(machineID)
            await runThemePush(machineID: machineID, socketPath: socketPath)
        } while themePushQueued.contains(machineID)
        themePushInFlight.remove(machineID)
    }

    private func runThemePush(machineID: String, socketPath: String) async {
        guard let link = links[machineID] else { return }
        guard let colors = await hostThemeColors(),
              let arguments = CloudTuiCommandLine.setDefaultColorsArguments(
                  socketPath: socketPath, foreground: colors.foreground, background: colors.background
              ) else { return }
        do {
            _ = try await link.run(arguments: arguments)
            #if DEBUG
            cmuxDebugLog("cloud.link.theme machine=\(machineID) fg=\(colors.foreground) bg=\(colors.background)")
            #endif
        } catch {
            #if DEBUG
            cmuxDebugLog("cloud.link.themeFailed machine=\(machineID) error=\(CloudMachineLink.errorText(error))")
            #endif
        }
    }

    private func store(link: CloudMachineLink, for machineID: String) {
        links[machineID] = link
    }

    /// `remote-probe --json` → `capabilities`; the control plane picks the machine host by
    /// them (a client that sends a User-Agent earns the branded host).
    nonisolated static func clientCapabilities(clientURL: URL) -> [String] {
        let process = Process()
        process.executableURL = clientURL
        process.arguments = ["remote-probe", "--json"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return []
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (object["app"] as? String) == "cmux-tui",
              let raw = object["capabilities"] as? [Any] else {
            return []
        }
        return raw.compactMap { $0 as? String }
    }
}
