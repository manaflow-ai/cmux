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
    private var browser: CloudBrowserProxyProcess?
    private var browserStarting: Task<CloudBrowserProxyEndpoint, Error>?

    init(connection: SSHTuiConnection, clientURL: URL, paths: CloudTuiClientPaths, isEnabled: @escaping @Sendable () -> Bool) {
        self.connection = connection
        self.clientURL = clientURL
        self.paths = paths
        self.isEnabled = isEnabled
    }

    func connected(machineID: String) async throws -> CloudMachineLink.Connected {
        guard machineID == connection.id else { throw CancellationError() }
        guard isEnabled() else { await disconnect(); throw CancellationError() }
        if let current, await current.isConnected, let ready = await current.connected { return ready }
        if let connecting { return try await connecting.value }
        let link = CloudMachineLink(machineID: machineID, clientURL: clientURL, paths: paths)
        current = link
        let attempt = Task {
            try await link.connect(route: "ssh://" + connection.configuration.destination,
                                   session: connection.session, carrier: true,
                                   timeout: .seconds(180), ssh: connection)
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
        browserStarting?.cancel()
        browserStarting = nil
        let proxy = browser
        browser = nil
        await proxy?.stop()
        await previous?.disconnect()
    }
}
