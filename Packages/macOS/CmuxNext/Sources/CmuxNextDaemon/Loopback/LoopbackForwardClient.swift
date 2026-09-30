public import Foundation
import Synchronization
import os

/// Browser traffic to one machine's loopback services over a dedicated
/// daemon connection (`loopback-forward-v1`,
/// plans/cmux-next/remote-localhost.md). A separate socket from the control
/// connection, so forwarded bytes never delay terminal traffic.
///
/// Connects on the first `open` and again on the first `open` after the
/// connection dropped; a drop fails every open stream (never a fallback to
/// this Mac). Nothing runs while no stream is wanted.
public actor LoopbackForwardClient {
    public typealias EndpointProvider = @Sendable () async throws -> DaemonEndpoint

    /// This client's receive window per stream.
    public static let receiveWindow = 256 * 1024
    public static let capability = DaemonCapabilities.loopbackForward

    private let endpoint: EndpointProvider
    private let requestTimeout: Duration
    private let openTimeout: Duration
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "loopback")
    private var transport: LineTransport?
    private var table = LoopbackStreamTable()
    private var connecting: Task<LineTransport, any Error>?
    private var nextStream: UInt64 = 1

    public init(requestTimeout: Duration = .seconds(2), openTimeout: Duration = .seconds(5),
                endpoint: @escaping EndpointProvider) {
        self.endpoint = endpoint
        self.requestTimeout = requestTimeout
        self.openTimeout = openTimeout
    }

    /// Opens a stream to `host:port` on the machine. `host` must be a
    /// loopback name or literal; the daemon refuses anything else.
    public func open(host: String, port: UInt16) async throws -> LoopbackStream {
        let transport = try await liveTransport()
        let id = nextStream
        nextStream += 1
        let table = table
        let stream = LoopbackStream(id: id, receiveWindow: Self.receiveWindow,
                                    sender: TransportLineSender(transport: transport), onFinish: { table.remove($0) })
        table.insert(stream)
        let request = LoopbackOpenRequest(stream: id, host: host, port: port, window: Self.receiveWindow)
        do {
            let response = try await DaemonConnection.perform(request, on: transport, timeout: openTimeout)
            stream.opened(address: response.address, sendWindow: response.window)
        } catch {
            stream.abandon()
            if let error = error as? DaemonError { throw Self.map(error) }
            throw error
        }
        if transport.isClosed { stream.connectionLost("closed while opening") }
        return stream
    }

    /// Open streams (diagnostics).
    public var openStreamCount: Int { table.count }

    /// Closes the connection and every stream.
    public func close() {
        connecting?.cancel()
        connecting = nil
        transport?.close()
        transport = nil
        for stream in table.removeAll() { stream.connectionLost("closed") }
    }

    // MARK: Private

    private func liveTransport() async throws -> LineTransport {
        if let transport, !transport.isClosed { return transport }
        transport = nil
        if let connecting { return try await connecting.value }
        let task = Task { try await self.connect() }
        connecting = task
        defer { connecting = nil }
        let transport = try await task.value
        self.transport = transport
        return transport
    }

    private func connect() async throws -> LineTransport {
        let endpoint: DaemonEndpoint
        do {
            endpoint = try await self.endpoint()
        } catch {
            throw LoopbackForwardError.unavailable(String(describing: error))
        }
        let transport: LineTransport
        do {
            transport = try LineTransport(path: endpoint.socketPath)
        } catch {
            throw LoopbackForwardError.unavailable(error.description)
        }
        // A fresh table per connection: streams of a dropped connection
        // cannot receive lines of the next one.
        let table = LoopbackStreamTable()
        self.table = table
        let logger = logger
        transport.start(
            onEvent: { name, line, _ in
                guard let event = LoopbackForwardEvent.decode(name: name, line: line) else { return }
                table.stream(event.stream)?.deliver(event)
            },
            onClose: { reason in
                let detail = switch reason {
                case .closedByClient: "closed"
                case .daemonShutdown: "daemon shut down"
                case .lost(let text): text
                }
                let streams = table.removeAll()
                if !streams.isEmpty { logger.info("loopback connection lost: \(detail, privacy: .public)") }
                for stream in streams { stream.connectionLost(detail) }
            })
        do {
            let identity = try await DaemonConnection.perform(IdentifyRequest(), on: transport, timeout: requestTimeout)
            guard identity.supports(Self.capability) else {
                transport.close()
                throw LoopbackForwardError.unsupported
            }
            _ = try await DaemonConnection.perform(
                SetClientInfoRequest(name: "cmux-next loopback", kind: "loopback-forward", capabilities: [Self.capability]),
                on: transport, timeout: requestTimeout)
        } catch let error as LoopbackForwardError {
            throw error
        } catch let error as DaemonError {
            transport.close()
            throw Self.map(error)
        }
        return transport
    }

    private static func map(_ error: DaemonError) -> LoopbackForwardError {
        switch error {
        case .command(_, let message, let code): .from(code: code, message: message)
        case .timedOut: .timedOut
        default: .unavailable(error.description)
        }
    }
}
