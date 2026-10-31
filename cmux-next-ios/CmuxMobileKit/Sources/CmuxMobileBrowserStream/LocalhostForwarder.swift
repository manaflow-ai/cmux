import CmuxMobileTransport
import Foundation
import Network
import os

private let log = Logger(subsystem: "dev.cmux.mobile", category: "localhost-forward")

/// A browser tab opened on this iPhone at `http(s)://localhost:<port>` loads the
/// Mac's page, as `ssh -L` would: this iPhone listens on its own `127.0.0.1:<port>`
/// (and `[::1]:<port>` when it can), which only this iPhone reaches, and sends each
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

        /// Hands over the listeners to close (the forward has none after).
        func take() -> [NWListener] {
            defer { v4 = nil; v6 = nil }
            return [v4, v6].compactMap { $0 }
        }
    }

    private let open: Open
    private var forwards: [UInt16: Forward] = [:]
    /// Listeners are down while the app is in the background or unlinked.
    private var suspended = false
    /// Ports this app listened on lately: their closed connections' TIME_WAIT would
    /// refuse a plain rebind, so these rebind with address reuse. Kept past `stop()`.
    private var held: [UInt16: ContinuousClock.Instant] = [:]
    /// Listeners of a port still closing: a cancelled listener holds its address until
    /// it reports `cancelled`, so the next bind of the port waits for it.
    private var closing: [UInt16: Task<Void, Never>] = [:]
    /// Longer than TIME_WAIT on the loopback (2 × MSL).
    static let heldFor: Duration = .seconds(60)
    /// Why the Mac last refused a connection to a port ("Nothing is listening on
    /// port 3000 on this Mac."), until a connection to it goes through.
    public private(set) var refusals: [UInt16: String] = [:]
    /// What happened to the connections pages made (tests and the log read it).
    struct Counts: Equatable {
        var accepted = 0
        var refused = 0
        var opened = 0
    }
    private(set) var counts = Counts()

    public init(open: @escaping Open) {
        self.open = open
    }

    /// The ports forwarded now (listening or waiting to listen again).
    public var ports: Set<UInt16> { Set(forwards.keys) }

    /// Whether `port` forwards to a Mac other than `macID` now.
    public func forwardsElsewhere(_ port: UInt16, than macID: String?) -> Bool {
        forwards[port].map { $0.macID != macID } ?? false
    }

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
        // Bound once (up, or ended by iOS): its closed connections may still hold the port.
        if forward.isUp || held[port] != nil { held[port] = .now }
        forward.binding?.cancel()
        close(forward.take(), port: port)
        refusals[port] = nil
    }

    /// Cancels `listeners` and records their closing, which the port's next bind awaits.
    private func close(_ listeners: [NWListener], port: UInt16) {
        guard !listeners.isEmpty else { return }
        let before = closing[port]
        closing[port] = Task {
            await before?.value
            for listener in listeners { await Self.closed(listener) }
        }
    }

    /// Waits until the port's earlier listeners closed.
    private func closedEarlier(_ port: UInt16) async {
        while let task = closing[port] {
            await task.value
            if closing[port] == task { closing[port] = nil }
        }
    }

    /// Cancels a listener and returns once it gave up its address.
    nonisolated static func closed(_ listener: NWListener) async {
        if case .cancelled = listener.state { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let once = OnceFlag()
            listener.stateUpdateHandler = { state in
                if case .cancelled = state, once.take() { continuation.resume() }
            }
            listener.cancel()
        }
    }

    /// Whether this app listened on the port within `heldFor`.
    private func heldLately(_ port: UInt16) -> Bool {
        let now = ContinuousClock.now
        held = held.filter { now - $0.value < Self.heldFor }
        return held[port] != nil
    }

    /// The app went to the background, or the link went: listeners stop (the ports stay known).
    public func suspend() {
        suspended = true
        for (port, forward) in forwards where forward.isUp { held[port] = .now }
        for (port, forward) in forwards { close(forward.take(), port: port) }
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
            close(forward.take(), port: port)
            await closedEarlier(port)
            let v4: NWListener
            do throws(Failure) {
                v4 = try await listen(host: .ipv4(.loopback), port: port, reuse: heldLately(port))
            } catch {
                return .failure(error)
            }
            let v6 = try? await listen(host: .ipv6(.loopback), port: port, reuse: heldLately(port))
            // Stopped, moved or suspended while these bound.
            guard forwards[port] === forward, !suspended, !Task.isCancelled else {
                close([v4] + [v6].compactMap { $0 }, port: port)
                return .failure(.superseded)
            }
            forward.v4 = v4
            forward.v6 = v6
            held[port] = .now
            log.notice("forwarding localhost:\(port, privacy: .public)\(v6 == nil ? " (IPv4 only)" : "", privacy: .public)")
            return .success(())
        }
        forward.binding = task
        let result = await task.value
        if forward.binding == task { forward.binding = nil }
        if case .failure(.portInUse) = result, forwards[port] === forward { forwards[port] = nil }
        return result
    }

    private func listen(host: NWEndpoint.Host, port: UInt16, reuse: Bool) async throws(Failure) -> NWListener {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { throw .unavailable("bad port") }
        let parameters = NWParameters.tcp
        // Bound to a loopback address: only this iPhone can connect. (`acceptLocalOnly`
        // is about the local network, not loopback, and refused these connections.)
        // Only a port this app held before is bound with reuse (its closed connections'
        // TIME_WAIT would refuse the rebind for half a minute). A first bind never is,
        // so no other app can share a port with it, and an app already on the port
        // makes it fail (`portInUse`).
        parameters.allowLocalEndpointReuse = reuse
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
        counts.accepted += 1
        guard let forward = forwards[port], !suspended else { return connection.cancel() }
        let open = open
        let opened = { @Sendable (macID: String?, port: UInt16) async throws -> any LinkChannel in
            await MainActor.run { self.counts.opened += 1 }
            return try await open(macID, port)
        }
        let refusal = await Self.pump(connection, port: port, macID: forward.macID, open: opened) { @Sendable in
            await MainActor.run { self.counts.refused += 1 }
        }
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
    nonisolated static func pump(_ connection: NWConnection, port: UInt16, macID: String?, open: Open,
                                 refused: @Sendable () async -> Void = {}) async -> String? {
        connection.start(queue: queue)
        let gate = LoopbackRequestGate(port: port)
        // The Mac hears of the connection only once a whole request head passed.
        var first = Data()
        while first.isEmpty {
            guard let data = await receive(connection) else { return nil }
            switch gate.check(data) {
            case .forward(let bytes): first = bytes
            case .refuse(let reason):
                log.notice("localhost:\(port, privacy: .public): refused a request (\(reason, privacy: .public))")
                await refused()
                return nil
            }
        }
        let channel: any LinkChannel
        do {
            channel = try await open(macID, port)
        } catch {
            return (error as? LinkError).flatMap { refusalCodes.contains($0.code) && !$0.message.isEmpty ? $0.message : nil }
        }
        let sentFirst = (try? await channel.send(first)) != nil
        // This iPhone → the Mac, every request through the gate.
        let upstream = Task {
            reading: while sentFirst, let data = await receive(connection) {
                switch gate.check(data) {
                case .forward(let bytes):
                    if bytes.isEmpty { continue }
                    do { try await channel.send(bytes) } catch { break reading }
                case .refuse(let reason):
                    log.notice("localhost:\(port, privacy: .public): refused a request (\(reason, privacy: .public))")
                    break reading
                }
            }
            await channel.close(code: "eof", reason: "")
        }
        // The Mac → this iPhone.
        var delivered = false
        while let data = try? await channel.receive() {
            delivered = true
            gate.replied(data)
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
