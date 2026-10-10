import CmuxCloud
import CmuxCloudTui
import Foundation
import CmuxCore

/// Owns one SSH carrier and shares it between native projections and control requests.
actor SSHTuiLinkManager: RemoteTuiLinkManaging {
    nonisolated let operations: CloudOperationRecorder? = nil
    /// The current connection is internal for app-host tests that verify an
    /// idle carrier adopts a replacement authentication agent.
    var connection: SSHTuiConnection
    private let clientURL: URL
    private let paths: CloudTuiClientPaths
    private let isEnabled: @Sendable () -> Bool
    /// Read at each carrier start, so an Integrations toggle applies on the next connect.
    private let agentHookProviders: @Sendable () -> [String]
    private var current: CloudMachineLink?
    private var connecting: Task<CloudMachineLink.Connected, Error>?
    private var checking: Task<Void, Error>?
    private var browser: CloudBrowserProxyProcess?
    private var browserStarting: Task<CloudBrowserProxyEndpoint, Error>?
    /// Browser forwards keyed by the loopback port they reach on the SSH host.
    private var loopbackForwards: [Int: LoopbackForwardProcess] = [:]
    private var loopbackForwardStarts: [Int: Task<UInt16, Error>] = [:]

    init(connection: SSHTuiConnection, clientURL: URL, paths: CloudTuiClientPaths, isEnabled: @escaping @Sendable () -> Bool,
         agentHookProviders: @escaping @Sendable () -> [String] = { [] }) {
        self.connection = connection
        self.clientURL = clientURL
        self.paths = paths
        self.isEnabled = isEnabled
        self.agentHookProviders = agentHookProviders
    }

    func connected(machineID: String) async throws -> CloudMachineLink.Connected {
        try await connected(machineID: machineID, preflight: false)
    }

    /// With `preflight`, a prompt-free `ssh … true` runs before the carrier
    /// starts, so an explicit open reports OpenSSH's failure in seconds like
    /// `ssh`. Restores and reconnects skip it: the carrier's own retries wait
    /// for a host or an agent that comes back, with one login per link.
    func connected(machineID: String, preflight: Bool, upgrade: Bool = false) async throws -> CloudMachineLink.Connected {
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
        var carrier = connection
        carrier.agentHookProviders = agentHookProviders()
        let attempt = Task { [carrier] in
            try await link.connect(route: "ssh://" + connection.configuration.destination,
                                   session: connection.session, carrier: true,
                                   timeout: deadline - ContinuousClock.now, ssh: carrier,
                                   sshUpgrade: upgrade)
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

    /// The OpenSSH options the next carrier dials with.
    var carrierSSHOptions: [String] { connection.configuration.sshOptions }

    /// Applies an explicit open's SSH options to this machine's next carrier.
    ///
    /// Machine identity ignores control options on purpose: restores drop them,
    /// and a restored workspace must find the machine it was bound to. So
    /// `--ssh-option ControlPath=none`, meant to leave a stale shared master,
    /// reaches the manager an earlier open created, whose options would
    /// otherwise win. A carrier that is not connected takes the new options;
    /// a connected one keeps running so its terminals do not drop. Restores
    /// never call this, because their options have already lost their controls.
    /// The whole connection is replaced, so the open's agent socket and command
    /// also apply to the next carrier. A carrier still connecting keeps the
    /// options it started with.
    func adopt(_ replacement: SSHTuiConnection) async {
        guard replacement.id == connection.id,
              (replacement.configuration.sshOptions != connection.configuration.sshOptions
               || replacement.configuration.agentSocketPath != connection.configuration.agentSocketPath
               || replacement.configuration.agentSocketPathOverrideIsSet != connection.configuration.agentSocketPathOverrideIsSet),
              connecting == nil else { return }
        let observed = current
        if let observed, await observed.isConnected { return }
        // The check above suspends; a carrier started meanwhile keeps its options.
        guard current === observed, connecting == nil else { return }
        connection = replacement
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
                                  environment: connection.sshProcessEnvironment, releaseHub: {})
        }
        browserStarting = task
        defer { if browserStarting == task { browserStarting = nil } }
        return try await task.value
    }

    /// The local listener port for one loopback port on the SSH host, started
    /// on first use and replaced when its `cmux-tui remote forward` child exits.
    /// `onExit` runs if the child exits after it was ready.
    func loopbackForward(machineID: String, port: Int,
                         onExit: @escaping @Sendable () -> Void = {}) async throws -> UInt16 {
        guard machineID == connection.id, (1...Int(UInt16.max)).contains(port) else { throw CancellationError() }
        // A pane owns this await, but the carrier is shared with terminals and
        // other browser panes. Race the shared connection wait against the
        // pane's cancellation so closing one route returns immediately without
        // cancelling the carrier that its siblings still need.
        _ = try await connectedCancellable(machineID: machineID)
        // The access model may have been stopped while the carrier was
        // connecting. A completed carrier must never resurrect that route by
        // launching a new forward after cancellation.
        try Task.checkCancellation()
        // Each await can interleave with another caller, so re-read the tables
        // until this caller either joins a forward or owns a fresh start.
        while true {
            if let starting = loopbackForwardStarts[port] { return try await starting.value }
            guard let existing = loopbackForwards[port] else { break }
            if let ready = await existing.readyPort, loopbackForwards[port] === existing { return ready }
            guard loopbackForwards[port] === existing, loopbackForwardStarts[port] == nil else { continue }
            loopbackForwards[port] = nil
            await existing.stop()
        }
        let forward = LoopbackForwardProcess()
        loopbackForwards[port] = forward
        let client = clientURL
        let arguments = loopbackForwardArguments(port: port)
        let environment = connection.sshProcessEnvironment
        let task = Task {
            try await forward.start(client: client, arguments: arguments, environment: environment, onExit: onExit)
        }
        loopbackForwardStarts[port] = task
        defer { if loopbackForwardStarts[port] == task { loopbackForwardStarts[port] = nil } }
        do {
            // A cancelled route (pane closed, model stopped) stops the child now,
            // not after the start timeout.
            let ready = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard loopbackForwards[port] === forward, isEnabled() else { throw CancellationError() }
            return ready
        } catch {
            if loopbackForwards[port] === forward { loopbackForwards[port] = nil }
            await forward.stop()
            throw error
        }
    }

    /// Waits for the shared carrier without allowing one canceled route to
    /// cancel the connection used by other projections.
    private func connectedCancellable(machineID: String) async throws -> CloudMachineLink.Connected {
        let result = CloudLinkFirstValue<Result<CloudMachineLink.Connected, any Error>>()
        let waiter = Task { [self] in
            do {
                result.resolve(.success(try await connected(machineID: machineID)))
            } catch {
                result.resolve(.failure(error))
            }
        }
        defer { waiter.cancel() }
        guard let outcome = await result.result else { throw CancellationError() }
        return try outcome.get()
    }

    func closeLoopbackForward(machineID: String, port: Int) async {
        guard machineID == connection.id else { return }
        loopbackForwardStarts.removeValue(forKey: port)?.cancel()
        await loopbackForwards.removeValue(forKey: port)?.stop()
    }

    /// The carrier's own route and SSH options, reaching one loopback port.
    private func loopbackForwardArguments(port: Int) -> [String] {
        var arguments = connection.arguments(stateDirectory: paths.stateDir.path, deviceName: CloudTuiClientPaths.deviceName())
        arguments[1] = "forward"
        arguments[2] = "ssh://" + connection.configuration.destination
        arguments.removeAll { ["--headless", "--json"].contains($0) }
        return arguments + ["--workspace-root", "/", "--port", String(port), "--scheme", "http"]
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
        let starts = loopbackForwardStarts.values
        loopbackForwardStarts.removeAll()
        starts.forEach { $0.cancel() }
        let forwards = loopbackForwards.values
        loopbackForwards.removeAll()
        for forward in forwards { await forward.stop() }
        await previous?.disconnect()
    }
}

extension SSHTuiLinkManager {
    /// Owns one `cmux-tui remote forward` process: a loopback listener on this
    /// Mac that carries browser traffic to one loopback port on the SSH host.
    actor LoopbackForwardProcess {
        private var process: Process?
        private var exit: CloudLinkFirstValue<Int32>?
        private var localPort: UInt16?
        private var stopped = false
        private var onExit: (@Sendable () -> Void)?

        /// The listener port while the child is running.
        var readyPort: UInt16? { process?.isRunning == true && !stopped ? localPort : nil }

        /// Starts the child and waits for the loopback URL it prints once listening.
        func start(client: URL, arguments: [String], environment: [String: String]?,
                   onExit: (@Sendable () -> Void)? = nil) async throws -> UInt16 {
            guard !stopped else { throw CancellationError() }
            self.onExit = onExit
            let child = Process()
            let output = Pipe()
            let errors = Pipe()
            let ended = CloudLinkFirstValue<Int32>()
            let ready = CloudLinkFirstValue<UInt16>()
            child.executableURL = client
            child.arguments = arguments
            child.environment = CloudBrowserProxyProcess.sanitizedEnvironment(environment ?? ProcessInfo.processInfo.environment)
            child.standardInput = FileHandle.nullDevice
            child.standardOutput = output
            child.standardError = errors
            child.terminationHandler = { terminated in
                ended.resolve(terminated.terminationStatus)
                ready.resolve(nil)
            }
            try child.run()
            process = child
            exit = ended

            let lines = CloudLinkPipe.lines(from: output.fileHandleForReading)
            Task {
                for await line in lines {
                    if let port = Self.listenerPort(fromURL: line) { ready.resolve(port) }
                }
                ready.resolve(nil)
            }
            // Drain stderr so a reconnecting SSH child cannot block on its pipe.
            let errorLines = CloudLinkPipe.lines(from: errors.fileHandleForReading)
            Task { for await _ in errorLines {} }
            Task { [weak self] in
                _ = await ended.result
                await self?.didExit()
            }

            do {
                let port = try await withThrowingTaskGroup(of: UInt16?.self) { group in
                    group.addTask { await ready.result }
                    group.addTask {
                        try await Task.sleep(for: .seconds(60))
                        throw CloudMachineLink.LinkError.timedOut
                    }
                    defer { group.cancelAll() }
                    return try await group.next() ?? nil
                }
                try Task.checkCancellation()
                guard !stopped, child.isRunning, let port else {
                    throw CloudMachineLink.LinkError.failureMessage(String(
                        localized: "ssh.tui.browserForward.ended",
                        defaultValue: "The SSH port forward ended before it was ready. Reload to reconnect."
                    ))
                }
                localPort = port
                return port
            } catch {
                await stop()
                throw error
            }
        }

        /// An exit after the listener was ready is reported once; a stop is not an exit.
        private func didExit() {
            guard !stopped, localPort != nil else { return }
            localPort = nil
            onExit?()
        }

        func stop() async {
            guard !stopped else { return }
            stopped = true
            localPort = nil
            onExit = nil
            if let process, let exit {
                // Retain Process until its termination callback fires, even when the caller cancels.
                let finished = Task.detached { await exit.result }
                if process.isRunning { process.terminate() }
                let forceStop = Task.detached {
                    do { try await Task.sleep(for: .seconds(3)) } catch { return }
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
                _ = await finished.value
                forceStop.cancel()
            }
            process = nil
            exit = nil
        }

        /// The port of a `http://127.0.0.1:<port>` listener URL, the only line the
        /// child prints; anything else is ignored.
        nonisolated static func listenerPort(fromURL line: String) -> UInt16? {
            guard let url = URLComponents(string: line.trimmingCharacters(in: .whitespaces)),
                  url.scheme == "http", url.host == "127.0.0.1",
                  let port = url.port, port > 0, port <= Int(UInt16.max) else { return nil }
            return UInt16(port)
        }
    }
}
