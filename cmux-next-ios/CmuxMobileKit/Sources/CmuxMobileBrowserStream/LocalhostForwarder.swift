import CmuxMobileTransport
import Foundation
import Network
import os

private let log = Logger(subsystem: "dev.cmux.mobile", category: "localhost-forward")

/// A browser tab opened on this iPhone at `http(s)://localhost:<port>` loads the
/// Mac's page, as `ssh -L` would: this iPhone listens on its own `127.0.0.1:<port>`
/// (and `[::1]:<port>` when it can) for local connections only, and sends each
/// connection over the Mac's link as a `localhost` channel, which the Mac
/// connects to the same port on its loopback (PROTOCOL.md `localhost`). The page
/// keeps its origin, so its cookies, absolute links and hot-reload socket work.
/// Every request passes `LoopbackRequestGate` first (no rebinding, no other site).
///
/// A port forwards to one Mac at a time. Listeners stop while the app is in the
/// background or unlinked, and come back for the same ports when it returns.
@MainActor
public final class LocalhostForwarder {
    /// Opens one connection to `port` on the Mac `macID`'s loopback (nil: the focused Mac).
    public typealias Open = @Sendable (_ macID: String?, _ port: UInt16) async throws -> any LinkChannel

    public enum Failure: Error, Equatable {
        /// Something on this iPhone already listens on the port.
        case portInUse
        /// The port was stopped, or moved to another Mac, while it was starting.
        case superseded
        /// The listener could not start for another reason.
        case unavailable(String)
    }

    private final class Forward {
        var macID: String?
        /// `127.0.0.1:<port>`: required, since `localhost` falls back to it.
        var v4: NWListener?
        /// `[::1]:<port>`: best effort (`localhost` tries it first).
        var v6: NWListener?
        /// The bind in flight: a second caller for the port waits for it.
        var binding: Task<Result<Void, Failure>, Never>?
        init(macID: String?) { self.macID = macID }

        var isUp: Bool { v4?.state == .ready }

        func cancel() {
            v4?.cancel()
            v6?.cancel()
            v4 = nil
            v6 = nil
        }
    }

    private let open: Open
    private var forwards: [UInt16: Forward] = [:]
    /// Listeners are down while the app is in the background or unlinked.
    private var suspended = false
    /// Why the Mac last refused a connection to a port ("Nothing is listening on
    /// port 3000 on this Mac."), until a connection to it goes through.
    public private(set) var refusals: [UInt16: String] = [:]

    public init(open: @escaping Open) {
        self.open = open
    }

    /// The ports forwarded now (listening or waiting to listen again).
    public var ports: Set<UInt16> { Set(forwards.keys) }

    /// Forwards `port` to `macID`'s loopback: returns once this iPhone listens on it.
    public func forward(port: UInt16, macID: String?) async throws(Failure) {
        guard port != 0 else { throw .unavailable("port 0") }
        let forward: Forward
        if let existing = forwards[port] {
            existing.macID = macID
            if existing.isUp { return }
            forward = existing
        } else {
            forward = Forward(macID: macID)
            forwards[port] = forward
        }
        // Unlinked or in the background: nothing to forward to now.
        if suspended { throw .unavailable("not connected") }
        try await bind(forward, port: port).get()
    }

    /// Stops the ports no native tab shows any more.
    public func retain(ports keep: Set<UInt16>) {
        for port in ports where !keep.contains(port) { stop(port) }
    }

    public func stop(_ port: UInt16) {
        guard let forward = forwards.removeValue(forKey: port) else { return }
        forward.binding?.cancel()
        forward.cancel()
        refusals[port] = nil
    }

    /// The app went to the background, or the link went: listeners stop (the ports stay known).
    public func suspend() {
        suspended = true
        for forward in forwards.values { forward.cancel() }
    }

    /// The app is active and linked again: the same ports listen again.
    public func resume() {
        suspended = false
        for (port, forward) in forwards where !forward.isUp && forward.binding == nil {
            // task-owner: one port's listener coming back; a later stop() cancels it
            Task { _ = await self.bind(forward, port: port) }
        }
    }

    /// Binds the port's listeners, or waits for the bind already in flight.
    private func bind(_ forward: Forward, port: UInt16) async -> Result<Void, Failure> {
        if let binding = forward.binding { return await binding.value }
        let task = Task { () -> Result<Void, Failure> in
            forward.cancel()
            let v4: NWListener
            do {
                v4 = try await listen(host: .ipv4(.loopback), port: port)
            } catch {
                return .failure(error)
            }
            let v6 = try? await listen(host: .ipv6(.loopback), port: port)
            // Stopped, moved or suspended while these bound.
            guard forwards[port] === forward, !suspended, !Task.isCancelled else {
                v4.cancel()
                v6?.cancel()
                return .failure(.superseded)
            }
            forward.v4 = v4
            forward.v6 = v6
            log.notice("forwarding localhost:\(port, privacy: .public)\(v6 == nil ? " (IPv4 only)" : "", privacy: .public)")
            return .success(())
        }
        forward.binding = task
        let result = await task.value
        if forward.binding == task { forward.binding = nil }
        if case .failure(.portInUse) = result, forwards[port] === forward { forwards[port] = nil }
        return result
    }

    private func listen(host: NWEndpoint.Host, port: UInt16) async throws(Failure) -> NWListener {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { throw .unavailable("bad port") }
        let parameters = NWParameters.tcp
        parameters.acceptLocalOnly = true
        // Listening again right after a stop (resume, Open on iPhone again) must not wait
        // out the closed connections' TIME_WAIT. An app holding the port without reuse
        // still makes this bind fail (`portInUse`).
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: host, port: endpointPort)
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw Self.failure(error)
        }
        listener.newConnectionHandler = { [weak self] connection in
            // task-owner: one forwarded connection; ends when either side closes
            Task { @MainActor [weak self] in
                guard let self else { return connection.cancel() }
                await self.serve(connection, port: port)
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

    /// One connection a page made to the port: to the port's Mac, and the Mac's refusal kept.
    private func serve(_ connection: NWConnection, port: UInt16) async {
        // A port stopped meanwhile forwards nothing (never to some other Mac).
        guard let forward = forwards[port], !suspended else { return connection.cancel() }
        let refusal = await Self.pump(connection, port: port, macID: forward.macID, open: open)
        // Kept before the page hears the connection end, so its card can say why.
        if forwards[port] === forward {
            if let refusal { refusals[port] = refusal } else if refusals[port] != nil { refusals[port] = nil }
        }
        connection.cancel()
    }

    nonisolated static let queue = DispatchQueue(label: "dev.cmux.mobile.localhost-forward")

    nonisolated static func failure(_ error: any Error) -> Failure {
        if case .posix(let code) = error as? NWError, code == .EADDRINUSE { return .portInUse }
        return .unavailable(String(describing: error))
    }

    /// The Mac's close codes that mean it refused the connection (with a sentence).
    nonisolated static let refusalCodes: Set<String> = ["unavailable", "bad_request", "unknown_service"]

    /// Passes one connection's bytes both ways until either side closes, every
    /// request through the gate. Returns the Mac's refusal, if it refused the
    /// connection before any reply. The caller cancels the connection.
    nonisolated static func pump(_ connection: NWConnection, port: UInt16, macID: String?, open: Open) async -> String? {
        connection.start(queue: queue)
        // The first request is checked before the Mac hears of the connection.
        var gate = LoopbackRequestGate(port: port)
        guard let first = await receive(connection) else { return nil }
        if case .refuse(let reason) = gate.check(first) {
            log.notice("localhost:\(port, privacy: .public): refused a request (\(reason, privacy: .public))")
            return nil
        }
        let channel: any LinkChannel
        do {
            channel = try await open(macID, port)
        } catch {
            return (error as? LinkError).flatMap { refusalCodes.contains($0.code) && !$0.message.isEmpty ? $0.message : nil }
        }
        let sendFirst = (try? await channel.send(first)) != nil
        // This iPhone → the Mac, every request through the gate.
        let upstream = Task { [gate] in
            var gate = gate
            while sendFirst, let data = await receive(connection) {
                if case .refuse(let reason) = gate.check(data) {
                    log.notice("localhost:\(port, privacy: .public): refused a request (\(reason, privacy: .public))")
                    break
                }
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
        await channel.close(code: "eof", reason: "")
        guard !delivered, let closed = channel.closedBy, refusalCodes.contains(closed.code), !closed.message.isEmpty else { return nil }
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
