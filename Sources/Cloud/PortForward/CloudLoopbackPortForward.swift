import Foundation
import Network
import os

nonisolated private let logger = Logger(subsystem: "com.cmuxterm.app", category: "CloudPortForward")

/// One loopback TCP listener that carries every accepted connection to one
/// service inside the Cloud VM network through the user-space WireGuard hub.
///
/// The listener binds `127.0.0.1` on an ephemeral port and holds no hub lease
/// while idle: each accepted connection claims the hub (starting it when
/// needed), runs the SOCKS5 CONNECT, relays bytes both ways, and releases the
/// claim when either side closes. Browser panes, and any other app on this
/// Mac, reach the VM port at `http://127.0.0.1:<localPort>` with no VPN and no
/// system-extension approval.
actor CloudLoopbackPortForward {
    enum ForwardError: Error, LocalizedError, Equatable {
        case listenerFailed(String)
        case listenerCancelled

        var errorDescription: String? {
            switch self {
            case .listenerFailed(let detail):
                return String(
                    format: String(
                        localized: "cloudTree.port.forwardListenerFailed",
                        defaultValue: "cmux could not open a local port for the forward: %@"
                    ),
                    detail
                )
            case .listenerCancelled:
                return String(
                    localized: "cloudTree.port.forwardListenerCancelled",
                    defaultValue: "The local port forward was closed before it started."
                )
            }
        }
    }

    private(set) var target: CloudPortForwardTarget
    /// The bound loopback port; 0 until ``start()`` returns.
    private(set) var localPort: UInt16 = 0
    private(set) var isListening = false
    private let relay: CloudPortForwardRelay
    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.cmuxterm.app.cloud-port-forward", qos: .userInitiated)
    private var connections: [UUID: NWConnection] = [:]
    /// Every connection the listener ever accepted, for diagnostics and tests.
    private(set) var acceptedConnectionCount = 0
    private var stopped = false
    private var started = false
    /// Resolves once the listener reports `.cancelled` or `.failed`, so a stop
    /// can wait until the port is actually released.
    private let listenerEnded = CloudLinkFirstValue<Bool>()

    init(target: CloudPortForwardTarget, dialer: any CloudHubDialing, relay: CloudPortForwardRelay? = nil) throws {
        self.target = target
        self.relay = relay ?? CloudPortForwardRelay(dialer: dialer)
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    var localURLString: String { "http://127.0.0.1:\(localPort)" }
    var activeConnectionCount: Int { connections.count }

    /// Binds the loopback listener and returns its port once it accepts.
    @discardableResult
    func start() async throws -> UInt16 {
        let bound = CloudLinkFirstValue<Result<UInt16, ForwardError>>()
        listener.stateUpdateHandler = { [weak self, listener, listenerEnded] state in
            switch state {
            case .ready:
                if let port = listener.port?.rawValue, port != 0 {
                    bound.resolve(.success(port))
                } else {
                    bound.resolve(.failure(.listenerFailed("the listener reported no port")))
                }
            case .failed(let error):
                bound.resolve(.failure(.listenerFailed(error.localizedDescription)))
                listenerEnded.resolve(true)
                Task { await self?.listenerDidFail(error) }
            case .cancelled:
                bound.resolve(.failure(.listenerCancelled))
                listenerEnded.resolve(true)
            case .setup, .waiting:
                break
            @unknown default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.accept(connection) }
        }
        started = true
        listener.start(queue: queue)
        switch await bound.result ?? .failure(.listenerCancelled) {
        case .success(let port):
            // The failure hop can land before this continuation resumes; a
            // listener that already died must not be reported as listening.
            guard !stopped else { throw ForwardError.listenerCancelled }
            localPort = port
            isListening = true
            return port
        case .failure(let error):
            // A listener that never became usable must not stay bound.
            await stop()
            throw error
        }
    }

    /// Claims the hub once and releases it, so a hub that cannot start is
    /// reported to the caller instead of surfacing as a browser error page.
    func warmUpHub() async throws {
        let claim = try await relay.dialer.claimHubSocket()
        await claim.release()
    }

    /// Points later connections at a new address; the local port stays the
    /// same, so panes and copied links keep working after a machine's address
    /// changes.
    func retarget(_ newTarget: CloudPortForwardTarget) {
        target = newTarget
    }

    /// Stops accepting and ends every connection. Returns once the listener
    /// has released its port, so a caller that closes a forward can rely on
    /// the local port being free again.
    func stop() async {
        tearDown()
        if started {
            _ = await listenerEnded.result
        }
    }

    private func tearDown() {
        stopped = true
        isListening = false
        listener.newConnectionHandler = nil
        listener.cancel()
        for connection in connections.values {
            connection.cancel()
        }
        connections.removeAll()
    }

    private func accept(_ connection: NWConnection) {
        guard !stopped else {
            connection.cancel()
            return
        }
        let id = UUID()
        connections[id] = connection
        acceptedConnectionCount += 1
        let target = self.target
        let relay = self.relay
        let queue = self.queue
        Task { [weak self] in
            do {
                try await connection.startAndWaitUntilReady(queue: queue)
            } catch {
                connection.cancel()
                await self?.connectionDidEnd(id)
                return
            }
            await relay.carry(connection, to: target, queue: queue)
            await self?.connectionDidEnd(id)
        }
    }

    private func connectionDidEnd(_ id: UUID) {
        connections[id] = nil
    }

    /// A listener that fails after it was ready is dead for good: tear it and
    /// its connections down so the forwarder replaces it on the next use.
    private func listenerDidFail(_ error: NWError) {
        logger.error("loopback listener on port \(self.localPort, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        tearDown()
    }
}
