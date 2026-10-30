import CmuxMobileTransport
import Foundation
import Network
import os

private let log = Logger(subsystem: "dev.cmux.mobile", category: "localhost-forward")

/// A browser tab opened on this iPhone at `http(s)://localhost:<port>` loads the
/// Mac's page, as `ssh -L` would: this iPhone listens on its own `127.0.0.1:<port>`
/// and `[::1]:<port>` (local connections only) and sends each connection over
/// the Mac's link as a `localhost` channel, which the Mac connects to the same
/// port on its loopback (PROTOCOL.md `localhost`). The page keeps its origin, so
/// its cookies, absolute links and hot-reload socket work.
///
/// A port on this iPhone forwards to one Mac at a time: the Mac whose tab
/// loaded it last.
@MainActor
public final class LocalhostForwarder {
    /// Opens one connection to `port` on the Mac `macID`'s loopback (nil: the focused Mac).
    public typealias Open = @Sendable (_ macID: String?, _ port: UInt16) async throws -> any LinkChannel

    public enum Failure: Error, Equatable {
        /// Something on this iPhone already listens on the port.
        case portInUse
        /// The listener could not start for another reason.
        case unavailable(String)
    }

    private final class Forward {
        var macID: String?
        var listeners: [NWListener] = []
        init(macID: String?) { self.macID = macID }
    }

    private let open: Open
    private var forwards: [UInt16: Forward] = [:]
    /// Why the Mac last refused a connection to a port ("Nothing is listening on
    /// port 3000 on this Mac."), until a connection to it goes through.
    public private(set) var refusals: [UInt16: String] = [:]

    public init(open: @escaping Open) {
        self.open = open
    }

    /// The ports forwarded now.
    public var ports: Set<UInt16> { Set(forwards.keys) }

    /// Forwards `port` to `macID`'s loopback: returns once this iPhone listens on it.
    public func forward(port: UInt16, macID: String?) async throws(Failure) {
        if let forward = forwards[port], forward.listeners.contains(where: { $0.state == .ready }) {
            forward.macID = macID
            return
        }
        stop(port)
        let forward = Forward(macID: macID)
        forwards[port] = forward
        // IPv4 must be ours: an app holding `127.0.0.1:<port>` would get some of the
        // page's requests. IPv6 is best effort (`localhost` tries `[::1]` first).
        let v4: NWListener
        do {
            v4 = try await listen(host: .ipv4(.loopback), port: port)
        } catch {
            if forwards[port] === forward { forwards[port] = nil }
            throw error
        }
        var bound = [v4]
        if let v6 = try? await listen(host: .ipv6(.loopback), port: port) { bound.append(v6) }
        // Another tab stopped or re-forwarded the port while these bound.
        guard forwards[port] === forward else {
            bound.forEach { $0.cancel() }
            return
        }
        forward.listeners = bound
        log.notice("forwarding localhost:\(port, privacy: .public) on \(bound.count, privacy: .public) address(es)")
    }

    /// Stops the ports no native tab shows any more.
    public func retain(ports keep: Set<UInt16>) {
        for port in ports where !keep.contains(port) { stop(port) }
    }

    public func stop(_ port: UInt16) {
        guard let forward = forwards.removeValue(forKey: port) else { return }
        forward.listeners.forEach { $0.cancel() }
        refusals[port] = nil
    }

    private func listen(host: NWEndpoint.Host, port: UInt16) async throws(Failure) -> NWListener {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { throw .unavailable("bad port") }
        let parameters = NWParameters.tcp
        parameters.acceptLocalOnly = true
        parameters.requiredLocalEndpoint = .hostPort(host: host, port: endpointPort)
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw Self.failure(error)
        }
        let open = open
        listener.newConnectionHandler = { [weak self] connection in
            // task-owner: one forwarded connection; ends when either side closes
            Task { @MainActor [weak self] in
                guard let self else { return connection.cancel() }
                let macID = self.forwards[port]?.macID
                let reason = await Self.pump(connection, port: port, macID: macID, open: open)
                if let reason { self.refusals[port] = reason } else { self.refusals[port] = nil }
            }
        }
        let ready = await withCheckedContinuation { (continuation: CheckedContinuation<NWError?, Never>) in
            let once = OnceFlag()
            listener.stateUpdateHandler = { [weak listener] state in
                switch state {
                case .ready:
                    if once.take() { continuation.resume(returning: nil) }
                case .failed(let error):
                    if once.take() { continuation.resume(returning: error) } else { listener?.cancel() }
                case .cancelled:
                    if once.take() { continuation.resume(returning: .posix(.ECANCELED)) }
                default:
                    break
                }
            }
            listener.start(queue: Self.queue)
        }
        if let ready {
            listener.cancel()
            throw Self.failure(ready)
        }
        return listener
    }

    static let queue = DispatchQueue(label: "dev.cmux.mobile.localhost-forward")

    nonisolated static func failure(_ error: any Error) -> Failure {
        if case .posix(let code) = error as? NWError, code == .EADDRINUSE { return .portInUse }
        return .unavailable(String(describing: error))
    }

    /// Passes one connection's bytes both ways until either side closes. Returns
    /// the Mac's refusal, if it refused (nothing listening on the port).
    nonisolated static func pump(_ connection: NWConnection, port: UInt16, macID: String?, open: Open) async -> String? {
        connection.start(queue: queue)
        let channel: any LinkChannel
        do {
            channel = try await open(macID, port)
        } catch {
            connection.cancel()
            return (error as? LinkError)?.message ?? String(describing: error)
        }
        // This iPhone → the Mac.
        let upstream = Task {
            while let data = await receive(connection) {
                do { try await channel.send(data) } catch { break }
            }
            await channel.close(code: "eof", reason: "")
        }
        // The Mac → this iPhone.
        var delivered = false
        while let data = try? await channel.receive() {
            delivered = true
            guard await send(connection, data) else { break }
        }
        upstream.cancel()
        connection.cancel()
        await channel.close(code: "eof", reason: "")
        guard !delivered, let closed = channel.closedBy, closed.code != "eof" else { return nil }
        return closed.message
    }

    nonisolated static func receive(_ connection: NWConnection) async -> Data? {
        await withCheckedContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, _, _ in
                // Data with the final segment is delivered; the next receive then ends.
                continuation.resume(returning: data.flatMap { $0.isEmpty ? nil : $0 })
            }
        }
    }

    nonisolated static func send(_ connection: NWConnection, _ data: Data) async -> Bool {
        await withCheckedContinuation { continuation in
            connection.send(content: data, completion: .contentProcessed { error in
                continuation.resume(returning: error == nil)
            })
        }
    }
}

/// True the first time only (a listener reports several states; one resumes the wait).
private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var taken = false

    func take() -> Bool {
        lock.withLock {
            defer { taken = true }
            return !taken
        }
    }
}
