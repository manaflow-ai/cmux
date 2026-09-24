import CmuxFoundation
import CmuxSurfaceCatalogModel
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

    nonisolated let operations: CloudOperationRecorder?
    private let isCloudEnabled: @Sendable () -> Bool
    private let paths: CloudTuiClientPaths
    private let clientURL: URL?
    private var cachedClientCapabilities: [String]?
    /// The app's in-process WireGuard hub; nil in tests that never touch the network.
    /// A machine whose route points into the private network is linked through it when
    /// the bundled client advertises `wireguard-hub`. Public routes are refused.
    private let hub: CloudWireGuardHub?
    /// Private routes come from the signed-in machine list. An enrolled client
    /// reconnects with this local fact and does not call the attach endpoint.
    private var privateRoutes: [String: String] = [:]
    private var privateAddressCandidates: [String: [String]] = [:]
    private var links: [String: CloudMachineLink] = [:]
    private var connecting: [String: Task<CloudMachineLink.Connected, Error>] = [:]
    private var browserProxies: [String: CloudBrowserProxyProcess] = [:]
    private var browserProxyStarts: [String: Task<CloudBrowserProxyEndpoint, Error>] = [:]
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
        operations: CloudOperationRecorder? = nil,
        isCloudEnabled: @escaping @Sendable () -> Bool = { true },
        hostThemeColors: @escaping @Sendable () async -> (foreground: String, background: String)? = {
            await MainActor.run {
                let app = GhosttyApp.shared
                return (app.defaultForegroundColor.hexString(), app.defaultBackgroundColor.hexString())
            }
        }
    ) {
        self.isCloudEnabled = isCloudEnabled
        self.operations = operations
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
        setPrivateAddresses(address.map { [$0] } ?? [], for: machineID)
    }

    /// A create receipt proved the machine's image serves the trusted
    /// private-network listener (snapshot-v2), so its first link dials
    /// `--carrier` like a machine linked before. Without this, New Machine's
    /// first link paid a control-plane attach request (a Mac-to-backend round
    /// trip plus a provider status read, ~0.3 s) before its first dial.
    func markTrustedCarrier(machineID: String) {
        guard paths.deviceFingerprint(for: machineID) == nil else { return }
        paths.saveDeviceFingerprint(CloudTuiClientPaths.carrierDeviceMarker, for: machineID)
    }

    func setPrivateAddresses(_ addresses: [String], for machineID: String) {
        var seen = Set<String>()
        let addresses = addresses.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        privateAddressCandidates[machineID] = addresses
        guard let address = addresses.first else {
            privateRoutes[machineID] = nil
            return
        }
        let host = address.contains(":") ? "[\(address)]" : address
        privateRoutes[machineID] = "ws://\(host):1337/v1/link"
    }

    func privateAddresses(for machineID: String) -> [String] {
        privateAddressCandidates[machineID] ?? []
    }

    func privateRoute(for machineID: String) -> String? {
        privateRoutes[machineID]
    }

    /// The link for `machineID`, connecting (and enrolling) if needed.
    func connected(machineID: String) async throws -> CloudMachineLink.Connected {
        guard isCloudEnabled() else {
            throw ManagerError.retryLater(String(
                localized: "cloud.feature.disabled",
                defaultValue: "Cloud Machines are temporarily unavailable."
            ))
        }
        if let context = CloudOperationContext.current {
            return try await context.withPhase(.connect) { try await self.connectMeasured(machineID: machineID) }
        }
        if let operations {
            return try await operations.perform(.connect, foreground: false) { try await self.connectMeasured(machineID: machineID) }
        }
        return try await connectMeasured(machineID: machineID)
    }

    private func connectMeasured(machineID: String) async throws -> CloudMachineLink.Connected {
        if let link = links[machineID], await link.isConnected, let connected = await link.connected {
            return connected
        }
        if let inFlight = connecting[machineID] {
            return try await inFlight.value
        }
        let correlationID = UUID().uuidString.lowercased()
        StartupBreadcrumbLog.append(
            "cloud.link.start",
            fields: [
                "machine": machineID,
                "knownDevice": paths.deviceFingerprint(for: machineID) == nil ? "0" : "1",
                "correlation": correlationID,
                "outcome": "started"
            ]
        )
        if let failure = lastFailure[machineID], Date().timeIntervalSince(failure.at) < retryBackoff {
            recordPreflightFailure(machineID: machineID, reason: "retry_backoff", correlationID: correlationID)
            throw ManagerError.retryLater(failure.error)
        }
        guard let clientURL else {
            recordPreflightFailure(machineID: machineID, reason: "client_missing", correlationID: correlationID)
            throw ManagerError.clientMissing
        }
        guard privateRoutes[machineID] != nil else {
            recordPreflightFailure(machineID: machineID, reason: "private_route_required", correlationID: correlationID)
            throw ManagerError.privateRouteRequired(machineID)
        }
#if DEBUG
        cmuxDebugLog("cloud.link.connect machine=\(machineID)")
        #endif
        let task = Task<CloudMachineLink.Connected, Error> { [paths, hub] in
            try Task.checkCancellation()
            let link = CloudMachineLink(machineID: machineID, clientURL: clientURL, paths: paths)
            self.store(link: link, for: machineID)
            let capabilities = self.resolvedClientCapabilities(clientURL: clientURL)
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
            guard let hub else { throw ManagerError.wireGuardHubMissing }
            try Task.checkCancellation()
            guard isCloudEnabled() else { throw VMClientError.cloudMachinesDisabled }
            let claim = try await CloudOperationContext.phase(.tunnel) { try await hub.acquire() }
            let releaseLease: @Sendable () async -> Void = { await hub.release(claim.lease) }
            let reachableRoute: String
            do {
                try Task.checkCancellation()
                reachableRoute = try await CloudOperationContext.phase(.route) { try await self.resolvedPrivateRoute(machineID: machineID, through: claim.ready) }
            } catch {
                await releaseLease()
                throw error
            }
            #if DEBUG
            cmuxDebugLog("cloud.link.wireguardHub machine=\(machineID) socket=\(claim.ready.socketPath)")
            #endif
            do {
                try Task.checkCancellation()
                let connected = try await link.connect(
                    route: reachableRoute,
                    session: session,
                    carrier: carrier,
                    timeout: connectTimeout,
                    wireguardHubSocket: claim.ready.socketPath,
                    releaseHubLease: releaseLease
                )
                try Task.checkCancellation()
                if carrier, knownFingerprint == nil {
                    paths.saveDeviceFingerprint(CloudTuiClientPaths.carrierDeviceMarker, for: machineID)
                }
                return connected
            } catch {
                await link.disconnect()
                throw error
            }
        }
        connecting[machineID] = task
        defer { if connecting[machineID] == task { connecting[machineID] = nil } }
        do {
            let connected = try await task.value
            guard connecting[machineID] == task, !task.isCancelled, isCloudEnabled() else { throw CancellationError() }
            lastFailure[machineID] = nil
            #if DEBUG
            cmuxDebugLog("cloud.link.connected machine=\(machineID) socket=\(connected.socketPath)")
            #endif
            StartupBreadcrumbLog.append(
                "cloud.link.connected",
                fields: [
                    "machine": machineID,
                    "session": connected.session,
                    "correlation": correlationID,
                    "outcome": "connected"
                ]
            )
            pushHostTheme(machineID: machineID, socketPath: connected.socketPath)
            return connected
        } catch {
            guard connecting[machineID] == task else { throw error }
            let text = CloudMachineLink.errorText(error)
            lastFailure[machineID] = (Date(), text)
            links[machineID] = nil
            #if DEBUG
            cmuxDebugLog("cloud.link.failed machine=\(machineID) error=\(String(reflecting: error)) text=\(text)")
            #endif
            StartupBreadcrumbLog.append(
                "cloud.link.failed",
                fields: [
                    "machine": machineID,
                    "error": CloudDiagnosticFailure.classify(error).rawValue,
                    "correlation": correlationID,
                    "outcome": "failed"
                ]
            )
            throw error
        }
    }

    func link(machineID: String) -> CloudMachineLink? {
        links[machineID]
    }

    /// A browser carrier can present the machine's stored device identity directly.
    /// Only a first-time machine needs the one-time trusted-listener preparation.
    nonisolated static func browserProxyNeedsTrustedListenerPreparation(deviceFingerprint: String?) -> Bool {
        deviceFingerprint == nil
    }

    /// One authenticated browser carrier per machine, sharing the app's userspace WireGuard hub.
    func browserProxy(machineID: String) async throws -> CloudBrowserProxyEndpoint {
        try Task.checkCancellation()
        guard isCloudEnabled(), privateRoutes[machineID] != nil else {
            throw ManagerError.privateRouteRequired(machineID)
        }
        if let starting = browserProxyStarts[machineID] { return try await browserProxyResult(starting) }
        let addresses = privateAddresses(for: machineID)
        if let existing = browserProxies[machineID] {
            let endpoint = await existing.readyEndpoint
            if browserProxies[machineID] !== existing { return try await browserProxy(machineID: machineID) }
            if existing.addresses == addresses, let endpoint { return endpoint }
            browserProxies[machineID] = nil
            await existing.stop()
            return try await browserProxy(machineID: machineID)
        }
        guard let clientURL, let hub else { throw ManagerError.wireGuardHubMissing }
        guard resolvedClientCapabilities(clientURL: clientURL).contains("browser-proxy") else {
            throw ManagerError.retryLater(String(localized: "cloud.browser.clientUpdateRequired", defaultValue: "Update cmux to connect to this Cloud page."))
        }
        let proxy = CloudBrowserProxyProcess(addresses: addresses)
        browserProxies[machineID] = proxy
        let task = Task<CloudBrowserProxyEndpoint, Error> {
            let knownFingerprint = self.paths.deviceFingerprint(for: machineID)
            let carrier: Bool
            if Self.browserProxyNeedsTrustedListenerPreparation(deviceFingerprint: knownFingerprint) {
                // Prepare the trusted listener through the control plane without
                // starting a second persistent sidebar carrier. The browser
                // carrier below is the only long-lived machine connection.
                let client = await MainActor.run { VMClient.shared }
                guard let client else {
                    throw VMClientError.malformedResponse("Cloud VM client is not available (not signed in).")
                }
                let endpoint = try await client.openCmuxRemote(
                    id: machineID,
                    deviceFingerprint: nil,
                    clientCapabilities: self.resolvedClientCapabilities(clientURL: clientURL)
                )
                guard endpoint.trustedCarrier else {
                    throw ManagerError.retryLater(String(
                        localized: "cloud.link.trustedListenerPending",
                        defaultValue: "The Cloud machine is still preparing remote access. Try again shortly."
                    ))
                }
                paths.saveDeviceFingerprint(CloudTuiClientPaths.carrierDeviceMarker, for: machineID)
                carrier = true
            } else {
                carrier = knownFingerprint == CloudTuiClientPaths.carrierDeviceMarker
            }
            try Task.checkCancellation()
            let claim = try await hub.acquire()
            let route: String
            do {
                route = try await self.resolvedPrivateRoute(machineID: machineID, through: claim.ready)
                try Task.checkCancellation()
            } catch {
                await hub.release(claim.lease)
                throw error
            }
            let arguments = CloudTuiCommandLine.browserProxyArguments(
                route: route, addresses: addresses, stateDir: self.paths.stateDir.path,
                wireGuardHubSocket: claim.ready.socketPath,
                carrier: carrier
            )
            return try await proxy.start(client: clientURL, arguments: arguments) { await hub.release(claim.lease) }
        }
        browserProxyStarts[machineID] = task
        Task { [weak self] in
            let result = await task.result
            await self?.browserProxyStartFinished(machineID: machineID, proxy: proxy, result: result)
        }
        let endpoint = try await browserProxyResult(task)
        guard browserProxies[machineID] === proxy else { throw CancellationError() }
        return endpoint
    }

    /// A pane may cancel its wait while another pane still needs the shared carrier.
    private func browserProxyResult(_ task: Task<CloudBrowserProxyEndpoint, Error>) async throws -> CloudBrowserProxyEndpoint {
        let result = CloudLinkFirstValue<Result<CloudBrowserProxyEndpoint, Error>>()
        Task { result.resolve(await task.result) }
        guard let value = await result.result else { throw CancellationError() }
        return try value.get()
    }

    private func browserProxyStartFinished(machineID: String, proxy: CloudBrowserProxyProcess, result: Result<CloudBrowserProxyEndpoint, Error>) async {
        guard browserProxies[machineID] === proxy else { return }
        browserProxyStarts[machineID] = nil
        if case .failure = result {
            browserProxies[machineID] = nil
            await proxy.stop()
        }
    }

    /// Records a preflight failure without mutating link retry state.
    private func recordPreflightFailure(machineID: String, reason: String, correlationID: String) {
        StartupBreadcrumbLog.append(
            "cloud.link.failed",
            fields: [
                "machine": machineID,
                "error": reason,
                "correlation": correlationID,
                "outcome": "failed"
            ]
        )
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
        let startingProxy = browserProxyStarts.removeValue(forKey: machineID)
        startingProxy?.cancel()
        let proxy = browserProxies.removeValue(forKey: machineID)
        await proxy?.stop()
        _ = await startingProxy?.result
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
        for task in connecting.values { task.cancel() }
        for id in Set(links.keys).union(browserProxies.keys).union(browserProxyStarts.keys) {
            await disconnect(machineID: id)
        }
        for task in connecting.values { task.cancel() }
        connecting.removeAll()
        lastFailure.removeAll()
    }

    /// Drops stale routing facts immediately. The registry owns and awaits
    /// each removed machine's asynchronous link/forward teardown separately.
    func retainAddresses(machineIDs: Set<String>) {
        privateRoutes = privateRoutes.filter { machineIDs.contains($0.key) }
        privateAddressCandidates = privateAddressCandidates.filter { machineIDs.contains($0.key) }
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
              let arguments = CloudTuiRequests.setDefaultColorsArguments(
                  socketPath: socketPath, foreground: colors.foreground, background: colors.background
              ) else { return }
        do {
            _ = try await link.run(arguments: arguments)
            #if DEBUG
            cmuxDebugLog("cloud.link.theme machine=\(machineID) fg=\(colors.foreground) bg=\(colors.background)")
            #endif
        } catch {
            if let operations {
                let context = await operations.begin(.environment, foreground: false)
                await operations.finish(context, error: error)
            }
            #if DEBUG
            cmuxDebugLog("cloud.link.themeFailed machine=\(machineID) error=\(CloudMachineLink.errorText(error))")
            #endif
        }
    }

    private func store(link: CloudMachineLink, for machineID: String) {
        links[machineID] = link
    }

    /// The cached capability probe, else a fresh probe cached on success; a
    /// failed probe reports none and leaves the cache for a later retry.
    private func resolvedClientCapabilities(clientURL: URL) -> [String] {
        if let cached = cachedClientCapabilities { return cached }
        guard let probed = Self.clientCapabilities(clientURL: clientURL) else { return [] }
        cachedClientCapabilities = probed
        return probed
    }

    /// `remote-probe --json` → `capabilities`; the control plane picks the machine host by
    /// them (a client that sends a User-Agent earns the branded host).
    nonisolated static func clientCapabilities(clientURL: URL) -> [String]? {
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
            return nil
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (object["app"] as? String) == "cmux-tui",
              let raw = object["capabilities"] as? [Any] else {
            return nil
        }
        return raw.compactMap { $0 as? String }
    }
}
