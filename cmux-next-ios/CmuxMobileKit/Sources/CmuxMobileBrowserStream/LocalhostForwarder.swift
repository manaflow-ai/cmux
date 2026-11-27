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
    /// Opens one connection to a Mac host. A nil host is the Mac's loopback.
    public typealias OpenHost = @Sendable (_ macID: String?, _ host: String?, _ port: UInt16) async throws -> any LinkChannel

    /// An origin-preserving HTTP CONNECT route for a named private host.
    public struct ProxyRoute: Hashable, Sendable {
        public let target: Target
        public let localPort: UInt16
        fileprivate let username: String
        fileprivate let password: String

        /// The Network proxy configuration WebKit installs for this route.
        public var configuration: ProxyConfiguration {
            var value = ProxyConfiguration(httpCONNECTProxy: .hostPort(
                host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: localPort)!))
            value.allowFailover = false
            value.matchDomains = [target.host ?? ""]
            value.applyCredential(username: username, password: password)
            return value
        }
    }

    public struct Target: Hashable, Sendable {
        public let host: String?
        public let port: UInt16

        public init(host: String?, port: UInt16) {
            self.host = Self.normalize(host)
            self.port = port
        }

        fileprivate static func normalize(_ host: String?) -> String? {
            guard let host = host?.trimmingCharacters(in: .whitespacesAndNewlines), !host.isEmpty else { return nil }
            let value = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
            return ["localhost", "127.0.0.1", "::1"].contains(value) ? nil : value
        }
    }

    public struct ProxyTarget: Hashable, Sendable {
        public let target: Target
        public let macID: String?

        public init(target: Target, macID: String?) {
            self.target = target
            self.macID = macID
        }
    }

    public enum Failure: Error, Equatable {
        /// Something on this iPhone already listens on the port.
        case portInUse
        /// The port was stopped, or moved to another Mac, while it was starting.
        case superseded
        /// The listener could not start for another reason.
        case unavailable(String)
        /// A phone listener already forwards this port to another named target.
        case targetInUse
    }

    private final class Forward {
        var macID: String?
        let host: String?
        /// `127.0.0.1:<port>`: required, since `localhost` falls back to it.
        var v4: NWListener?
        /// `[::1]:<port>`: best effort (`localhost` tries it first).
        var v6: NWListener?
        /// The bind in flight: a second caller for the port waits for it.
        var binding: Task<Result<Void, Failure>, Never>?
        init(macID: String?, host: String?) {
            self.macID = macID
            self.host = Target.normalize(host)
        }

        var isUp: Bool { v4?.state == .ready }

        /// Hands over the listeners to close (the forward has none after).
        func take() -> [NWListener] {
            defer { v4 = nil; v6 = nil }
            return [v4, v6].compactMap { $0 }
        }
    }

    private final class ProxyForward {
        let target: Target
        let macID: String?
        let username: String
        let password: String
        var listener: NWListener?
        var binding: Task<Result<UInt16, Failure>, Never>?
        var bindingID: UInt = 0
        var connections: [ObjectIdentifier: NWConnection] = [:]

        init(target: Target, macID: String?) {
            self.target = target
            self.macID = macID
            username = UUID().uuidString
            password = UUID().uuidString
        }
    }

    private let openHost: OpenHost
    private var forwards: [UInt16: Forward] = [:]
    private var proxies: [ProxyKey: ProxyForward] = [:]
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
    private var targetRefusals: [Target: String] = [:]
    /// What happened to the connections pages made (tests and the log read it).
    struct Counts: Equatable {
        var accepted = 0
        var refused = 0
        var opened = 0
    }
    private(set) var counts = Counts()

    public init(open: @escaping Open) {
        self.openHost = { macID, host, port in
            guard host == nil else {
                throw LinkError(code: "unknown_service", message: "This Mac does not forward named hosts")
            }
            return try await open(macID, port)
        }
    }

    public init(openHost: @escaping OpenHost) {
        self.openHost = openHost
    }

    private struct ProxyKey: Hashable {
        let target: Target
        let macID: String?
    }

    /// The ports forwarded now (listening or waiting to listen again).
    public var ports: Set<UInt16> { Set(forwards.keys) }

    /// Whether `port` forwards to a Mac other than `macID` now.
    public func forwardsElsewhere(_ port: UInt16, than macID: String?) -> Bool {
        forwardsElsewhere(host: nil, port: port, than: macID)
    }

    /// Whether `host:port` is already owned by another Mac or host.
    public func forwardsElsewhere(host: String?, port: UInt16, than macID: String?) -> Bool {
        guard let forward = forwards[port] else { return false }
        return forward.host != Target.normalize(host) || forward.macID != macID
    }

    /// Whether this exact target is currently listening for this Mac.
    public func isForwarded(host: String?, port: UInt16, macID: String?) -> Bool {
        guard let forward = forwards[port] else { return false }
        return forward.host == Target.normalize(host) && forward.macID == macID && forward.isUp
    }

    /// Forwards `port` to `macID`'s loopback: returns once this iPhone listens on it.
    public func forward(port: UInt16, macID: String?) async throws(Failure) {
        try await forward(port: port, host: nil, macID: macID)
    }

    /// Forwards a loopback or named host through the Mac's localhost service.
    public func forward(port: UInt16, host: String?, macID: String?) async throws(Failure) {
        guard port != 0 else { throw .unavailable("port 0") }
        let targetHost = Target.normalize(host)
        let forward: Forward
        if let existing = forwards[port] {
            guard existing.host == targetHost else { throw .targetInUse }
            existing.macID = macID
            if existing.isUp { return }
            forward = existing
        } else {
            forward = Forward(macID: macID, host: targetHost)
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

    /// Stops named-host proxy routes no tab uses any longer.
    public func retain(proxies keep: Set<ProxyTarget>) {
        for key in Array(proxies.keys) where !keep.contains(.init(target: key.target, macID: key.macID)) {
            stopProxy(key)
        }
    }

    /// Starts (or reuses) a loopback CONNECT listener for a named host. The
    /// returned configuration matches the named origin, so WebKit keeps its
    /// URL, cookies, TLS SNI and WebSocket origin intact.
    public func proxy(host: String, port: UInt16, macID: String?) async throws(Failure) -> ProxyRoute {
        guard let normalized = Target.normalize(host), port != 0 else { throw .unavailable("bad private host") }
        let target = Target(host: normalized, port: port)
        let key = ProxyKey(target: target, macID: macID)
        let route: ProxyForward
        if let existing = proxies[key] {
            route = existing
        } else {
            route = ProxyForward(target: target, macID: macID)
            proxies[key] = route
        }
        guard !suspended else { throw .unavailable("not connected") }
        let localPort: UInt16
        if let listener = route.listener, listener.state == .ready, let port = listener.port?.rawValue {
            localPort = port
        } else if let binding = route.binding {
            localPort = try await binding.value.get()
        } else {
            let (task, bindingID) = startProxyBinding(route, key: key)
            let result = await task.value
            if route.bindingID == bindingID { route.binding = nil }
            localPort = try result.get()
        }
        return ProxyRoute(target: target, localPort: localPort, username: route.username, password: route.password)
    }

    private func stopProxy(_ key: ProxyKey) {
        guard let route = proxies.removeValue(forKey: key) else { return }
        route.binding?.cancel()
        route.listener?.cancel()
        route.listener = nil
        for connection in route.connections.values { connection.cancel() }
        route.connections.removeAll()
    }

    /// Registers a proxy bind before starting it, so concurrent callers and
    /// resume cannot create two listeners for the same route.
    private func startProxyBinding(_ route: ProxyForward, key: ProxyKey) -> (Task<Result<UInt16, Failure>, Never>, UInt) {
        route.bindingID &+= 1
        let bindingID = route.bindingID
        let task = Task { () -> Result<UInt16, Failure> in
            do { return .success(try await self.bindProxy(route, key: key)) }
            catch let error as Failure { return .failure(error) }
            catch { return .failure(.unavailable(String(describing: error))) }
        }
        route.binding = task
        return (task, bindingID)
    }

    private func bindProxy(_ route: ProxyForward, key: ProxyKey) async throws(Failure) -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener: NWListener
        do { listener = try NWListener(using: parameters) }
        catch { throw .unavailable(String(describing: error)) }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor [weak self] in
                guard let self else { connection.cancel(); return }
                await self.serveProxy(connection, key: key)
            }
        }
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<Result<UInt16, Failure>, Never>) in
            let once = OnceFlag()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready where once.take():
                    continuation.resume(returning: .success(listener.port?.rawValue ?? 0))
                case .failed(let error) where once.take():
                    continuation.resume(returning: .failure(Self.failure(error)))
                case .cancelled where once.take():
                    continuation.resume(returning: .failure(.superseded))
                default: break
                }
            }
            listener.start(queue: Self.queue)
        }
        let port = try result.get()
        guard port != 0, proxies[key] === route, !suspended, !Task.isCancelled else {
            listener.cancel()
            throw .superseded
        }
        route.listener = listener
        log.notice("private host proxy \(route.target.host ?? "?", privacy: .public):\(route.target.port, privacy: .public) on \(port, privacy: .public)")
        return port
    }

    public func stop(_ port: UInt16) {
        guard let forward = forwards.removeValue(forKey: port) else { return }
        // Bound once (up, or ended by iOS): its closed connections may still hold the port.
        if forward.isUp || held[port] != nil { held[port] = .now }
        forward.binding?.cancel()
        close(forward.take(), port: port)
        refusals[port] = nil
        targetRefusals = targetRefusals.filter { $0.key.port != port }
    }

    public func refusal(host: String?, port: UInt16) -> String? {
        targetRefusals[Target(host: host, port: port)] ?? (host == nil ? refusals[port] : nil)
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
        for route in proxies.values {
            route.binding?.cancel()
            route.binding = nil
            route.listener?.cancel()
            route.listener = nil
            for connection in route.connections.values { connection.cancel() }
            route.connections.removeAll()
        }
    }

    /// The app is active and linked again: the same ports listen again.
    public func resume() {
        suspended = false
        for (port, forward) in forwards where !forward.isUp && forward.binding == nil {
            // task-owner: one port's listener coming back; a later stop() cancels it
            Task { _ = await self.bind(forward, port: port) }
        }
        for (key, route) in proxies where route.listener == nil && route.binding == nil {
            let (task, bindingID) = startProxyBinding(route, key: key)
            Task {
                _ = await task.value
                if route.bindingID == bindingID { route.binding = nil }
            }
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
        forward.binding = nil
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
        let opener = openHost
        let opened = { @Sendable (macID: String?, host: String?, port: UInt16) async throws -> any LinkChannel in
            await MainActor.run { self.counts.opened += 1 }
            return try await opener(macID, host, port)
        }
        let refusal = await Self.pump(connection, host: forward.host, port: port, macID: forward.macID, open: opened) { @Sendable in
            await MainActor.run { self.counts.refused += 1 }
        }
        // Kept before the page hears the connection end, so its card can say why.
        if forwards[port] === forward {
            let target = Target(host: forward.host, port: port)
            if let refusal {
                refusals[port] = refusal
                targetRefusals[target] = refusal
            } else {
                refusals[port] = nil
                targetRefusals[target] = nil
            }
        }
        connection.cancel()
    }

    private func serveProxy(_ connection: NWConnection, key: ProxyKey) async {
        guard let route = proxies[key], !suspended else { connection.cancel(); return }
        let connectionID = ObjectIdentifier(connection)
        route.connections[connectionID] = connection
        defer {
            route.connections.removeValue(forKey: connectionID)
            connection.cancel()
        }
        connection.start(queue: Self.queue)
        guard let (head, remainder) = await Self.proxyHead(connection) else {
            _ = await Self.send(connection, Data("HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8))
            return
        }
        guard let request = Self.proxyRequest(head) else {
            _ = await Self.send(connection, Data("HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8))
            return
        }
        guard request.authority.lowercased() == Self.authority(host: route.target.host!, port: route.target.port).lowercased() else {
            _ = await Self.send(connection, Data("HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8))
            return
        }
        guard request.authorization == Self.authorization(username: route.username, password: route.password) else {
            _ = await Self.send(connection, Data("HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic realm=\"cmux\"\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8))
            return
        }
        let channel: any LinkChannel
        do {
            await MainActor.run { self.counts.opened += 1 }
            channel = try await openHost(route.macID, route.target.host, route.target.port)
        } catch {
            let linkError = error as? LinkError
            let status = linkError?.code == "forbidden" ? "403 Forbidden" : "502 Bad Gateway"
            let body = linkError?.message ?? "The Mac refused this private host."
            let response = "HTTP/1.1 \(status)\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            _ = await Self.send(connection, Data(response.utf8))
            if let linkError, Self.refusalCodes.contains(linkError.code) {
                await MainActor.run { self.targetRefusals[route.target] = linkError.message }
            }
            return
        }
        guard proxies[key] === route, !suspended else {
            await channel.close(code: "superseded", reason: "")
            return
        }
        guard await Self.send(connection, Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8)) else {
            await channel.close(code: "eof", reason: "")
            return
        }
        await Self.pumpRaw(connection, channel: channel, initial: remainder)
    }

    private struct ProxyRequest {
        let authority: String
        let authorization: String?
    }

    private nonisolated static func proxyRequest(_ data: Data) -> ProxyRequest? {
        let text = String(decoding: data, as: UTF8.self)
        guard let end = text.range(of: "\r\n\r\n"), let line = text[..<end.lowerBound].split(separator: "\r\n").first else { return nil }
        let parts = line.split(separator: " ")
        guard parts.count == 3, parts[0].uppercased() == "CONNECT" else { return nil }
        var auth: String?
        for header in text[..<end.lowerBound].split(separator: "\r\n").dropFirst() {
            let bits = header.split(separator: ":", maxSplits: 1).map(String.init)
            if bits.count == 2, bits[0].trimmingCharacters(in: .whitespaces).lowercased() == "proxy-authorization" {
                auth = bits[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return ProxyRequest(authority: String(parts[1]), authorization: auth)
    }

    private nonisolated static func proxyHead(_ connection: NWConnection) async -> (Data, Data)? {
        var data = Data()
        while data.count <= 64 * 1024 {
            guard let part = await receive(connection) else { return nil }
            data.append(part)
            if let range = data.range(of: Data("\r\n\r\n".utf8)) {
                return (data, data.subdata(in: range.upperBound..<data.endIndex))
            }
        }
        return nil
    }

    private nonisolated static func authority(host: String, port: UInt16) -> String {
        "\(host.contains(":") ? "[\(host)]" : host):\(port)"
    }

    private nonisolated static func authorization(username: String, password: String) -> String {
        "Basic \(Data("\(username):\(password)".utf8).base64EncodedString())"
    }

    private nonisolated static func pumpRaw(_ connection: NWConnection, channel: any LinkChannel, initial: Data) async {
        if !initial.isEmpty { try? await channel.send(initial) }
        let upstream = Task {
            while let data = await receive(connection) {
                do { try await channel.send(data) } catch { break }
            }
            await channel.close(code: "eof", reason: "")
        }
        while let data = try? await channel.receive() {
            guard await send(connection, data) else { break }
        }
        upstream.cancel()
        await channel.close(code: "eof", reason: "")
    }

    nonisolated static let queue = DispatchQueue(label: "dev.cmux.mobile.localhost-forward")

    nonisolated static func failure(_ error: any Error) -> Failure {
        if case .posix(let code) = error as? NWError, code == .EADDRINUSE { return .portInUse }
        return .unavailable(String(describing: error))
    }

    /// The Mac's close codes that mean it refused the connection (with a sentence).
    nonisolated static let refusalCodes: Set<String> = ["unavailable", "bad_request", "forbidden", "unknown_service"]

    /// Passes one connection's bytes both ways until either side closes, every
    /// request through the gate. Returns the Mac's refusal, if it refused the
    /// connection before any reply. The caller cancels the connection.
    nonisolated static func pump(_ connection: NWConnection, host: String? = nil, port: UInt16, macID: String?, open: OpenHost,
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
            channel = try await open(macID, host, port)
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
