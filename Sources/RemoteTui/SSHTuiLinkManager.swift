import CmuxCloud
import CmuxCloudTui
import Foundation
import CmuxCore

/// Owns one SSH carrier and shares it between native projections and control requests.
actor SSHTuiLinkManager: RemoteTuiLinkManaging {
    nonisolated let operations: CloudOperationRecorder? = nil
    private let connection: SSHTuiConnection
    private let clientURL: URL
    private let paths: CloudTuiClientPaths
    private let isEnabled: @Sendable () -> Bool
    private var current: CloudMachineLink?
    private var connecting: Task<CloudMachineLink.Connected, Error>?
    private var checking: Task<Void, Error>?
    private var browser: CloudBrowserProxyProcess?
    private var browserStarting: Task<CloudBrowserProxyEndpoint, Error>?

    init(connection: SSHTuiConnection, clientURL: URL, paths: CloudTuiClientPaths, isEnabled: @escaping @Sendable () -> Bool) {
        self.connection = connection
        self.clientURL = clientURL
        self.paths = paths
        self.isEnabled = isEnabled
    }

    func connected(machineID: String) async throws -> CloudMachineLink.Connected {
        try await connected(machineID: machineID, preflight: false)
    }

    /// With `preflight`, a prompt-free `ssh … true` runs before the carrier
    /// starts, so an explicit open reports OpenSSH's failure in seconds like
    /// `ssh`. Restores and reconnects skip it: the carrier's own retries wait
    /// for a host or an agent that comes back, with one login per link.
    func connected(machineID: String, preflight: Bool) async throws -> CloudMachineLink.Connected {
        guard machineID == connection.id else { throw CancellationError() }
        guard isEnabled() else { await disconnect(); throw CancellationError() }
        if let current, await current.isConnected, let ready = await current.connected { return ready }
        // The preflight spends from a new carrier's startup budget, which the
        // socket call's own deadline was sized around. A carrier a restore
        // started during the check keeps its own budget.
        let deadline = ContinuousClock.now + .seconds(180)
        if preflight {
            // Opens share one check, so a route asks for one login at a time.
            // Only opens wait on it: a restore arriving meanwhile starts or
            // joins the carrier on its own, and an open behind a restore's
            // retrying carrier still fails in seconds.
            let check = checking ?? Task { try await SSHTuiPreflight(connection: connection).run() }
            checking = check
            defer { if checking == check { checking = nil } }
            let failure: Error?
            do { try await check.value; failure = nil } catch { failure = error }
            try Task.checkCancellation()
            guard isEnabled() else { await disconnect(); throw CancellationError() }
            // A carrier that logged in meanwhile answers the open, whatever
            // the check reported before it.
            if let current, await current.isConnected, let ready = await current.connected { return ready }
            if let failure { throw failure }
        }
        if let connecting { return try await connecting.value }
        let link = CloudMachineLink(machineID: machineID, clientURL: clientURL, paths: paths)
        current = link
        let attempt = Task {
            try await link.connect(route: "ssh://" + connection.configuration.destination,
                                   session: connection.session, carrier: true,
                                   timeout: deadline - ContinuousClock.now, ssh: connection)
        }
        connecting = attempt
        defer { if connecting == attempt { connecting = nil } }
        do {
            let ready = try await attempt.value
            guard connecting == attempt, !attempt.isCancelled, isEnabled() else { throw CancellationError() }
            return ready
        } catch {
            await link.disconnect()
            if current === link { current = nil }
            throw error
        }
    }

    func link(machineID: String) -> CloudMachineLink? {
        machineID == connection.id ? current : nil
    }

    func status(machineID: String) async -> CloudMachineLinkManager.LinkStatus? {
        guard machineID == connection.id, let current else { return nil }
        let state = await current.state
        let error = await current.lastError
        return .init(state: state, error: error)
    }

    func privateAddresses(for machineID: String) -> [String] { ["127.0.0.1"] }

    /// The SSH carrier always forwards over loopback, so metadata never moves its route.
    func setPrivateAddresses(_ addresses: [String], for machineID: String) {}

    func browserProxy(machineID: String) async throws -> CloudBrowserProxyEndpoint {
        guard machineID == connection.id else { throw CancellationError() }
        _ = try await connected(machineID: machineID)
        if let browser, let ready = await browser.readyEndpoint { return ready }
        if let browserStarting { return try await browserStarting.value }
        let proxy = CloudBrowserProxyProcess(addresses: ["127.0.0.1", "localhost", "::1"])
        browser = proxy
        let task = Task {
            try await proxy.start(client: clientURL, arguments: connection.browserArguments(stateDirectory: paths.stateDir.path),
                                  environment: connection.configuration.sshProcessEnvironment, releaseHub: {})
        }
        browserStarting = task
        defer { if browserStarting == task { browserStarting = nil } }
        return try await task.value
    }

    /// Detaching a Mac closes its carrier, never the daemon or its terminal processes.
    func disconnect() async {
        let previous = current
        current = nil
        let attempt = connecting
        connecting = nil
        attempt?.cancel()
        checking?.cancel()
        checking = nil
        browserStarting?.cancel()
        browserStarting = nil
        let proxy = browser
        browser = nil
        await proxy?.stop()
        await previous?.disconnect()
    }
}
