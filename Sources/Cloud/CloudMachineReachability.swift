import Foundation
import Network

/// The one gate every Cloud VM dial passes through before anything opens a
/// socket to a machine.
///
/// Cloud machines sit on the account's private network (RFC 1918 / ULA
/// addresses, `10.16.x.x`, `fd0b:…`) with no public ports, so the only way a
/// packet from this Mac reaches one is through the WireGuard tunnel
/// (`cmux vpn up`). With the tunnel down, a dial to that address is routed at
/// the default gateway and dropped: no RST, no ICMP, just silence until some
/// far-away timeout. Every attach surface used to inherit that silence.
///
/// Two layers, both decided from the destination rather than a global flag:
///
/// 1. **Route gate.** If the destination address is private and this Mac does
///    not currently carry the tunnel (wg-quick's runtime record for the
///    interface exists *and* a local interface holds one of the tunnel's own
///    configured addresses), the dial is refused up front with
///    ``VMClientError/tunnelDown(machine:address:)``. A public destination is
///    never gated: the tunnel is irrelevant to it.
/// 2. **Bounded dial.** The TCP handshake to the destination is raced against
///    a short deadline. A destination that does not answer in time fails with
///    ``VMClientError/machineUnreachable(machine:address:privateNetwork:)``,
///    which carries the same fix when the address is private. A connection
///    that is *refused* counts as reachable: the address answers, the daemon
///    on it is simply not listening yet (a machine still booting), and the
///    transport's own retry loop owns that case.
///
/// Every dependency is injected so the decision table is testable without a
/// network: which addresses the tunnel would carry, which addresses the Mac
/// holds right now, how a dial is attempted, and which clock bounds it.
struct CloudMachineReachability: Sendable {
    /// Why a dial attempt did not complete a handshake.
    enum DialFailure: Error, Equatable, Sendable {
        /// The address answered with a reset: reachable, nothing listening.
        case refused
        /// The stack knows the address cannot be reached (no route, host or
        /// network unreachable, DNS failure).
        case unreachable(String)
        /// No answer of any kind before the deadline.
        case timedOut
    }

    /// The addresses the tunnel's `[Interface] Address =` lines name; empty
    /// when this Mac has never enrolled.
    var tunnelAddresses: @Sendable () -> Set<String>
    /// Every address a local interface currently holds (numeric, lowercase).
    var localAddresses: @Sendable () -> Set<String>
    /// Whether wg-quick's runtime record for the tunnel's interface exists.
    /// Required alongside an address match because every enrollment hands this
    /// Mac the same tunnel-side address, so an interface left up for a
    /// different enrollment matches the address while routing nowhere useful.
    var tunnelInterfacePresent: @Sendable () -> Bool
    /// Attempts a TCP handshake with `host:port`; returns on success, throws a
    /// ``DialFailure`` otherwise. It may take arbitrarily long: the caller
    /// bounds it.
    var dial: @Sendable (_ host: String, _ port: Int) async throws -> Void
    /// How long the handshake may take before the destination counts as
    /// unreachable. A few seconds: over the tunnel a handshake is tens of
    /// milliseconds, and a route that swallows SYNs never answers at all.
    var connectTimeout: Duration
    var clock: any Clock<Duration>

    init(
        tunnelAddresses: @escaping @Sendable () -> Set<String>,
        localAddresses: @escaping @Sendable () -> Set<String>,
        tunnelInterfacePresent: @escaping @Sendable () -> Bool = { true },
        dial: @escaping @Sendable (_ host: String, _ port: Int) async throws -> Void,
        connectTimeout: Duration = .seconds(4),
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.tunnelAddresses = tunnelAddresses
        self.localAddresses = localAddresses
        self.tunnelInterfacePresent = tunnelInterfacePresent
        self.dial = dial
        self.connectTimeout = connectTimeout
        self.clock = clock
    }

    /// The production gate: the wg-quick config this Mac enrolled with,
    /// `getifaddrs`, and a Network.framework TCP handshake.
    static func live(tunnel: VMTunnelManager = VMTunnelManager()) -> CloudMachineReachability {
        CloudMachineReachability(
            tunnelAddresses: { tunnel.configuredTunnelAddresses() },
            localAddresses: { VMTunnelManager.localInterfaceAddresses() },
            tunnelInterfacePresent: { tunnel.runtimeInterfacePresent() },
            dial: { host, port in try await Self.tcpHandshake(host: host, port: port) }
        )
    }

    /// A gate that never refuses and never dials: for callers (tests, previews)
    /// that need a `VMClient` with no network semantics at all.
    static let permissive = CloudMachineReachability(
        tunnelAddresses: { [] },
        localAddresses: { [] },
        dial: { _, _ in }
    )

    /// Whether this Mac currently carries the tunnel: wg-quick's runtime record
    /// for the interface exists and a local interface holds one of the tunnel's
    /// configured addresses. Same definition as
    /// ``VMTunnelManager/wgQuickInterfaceUp()``, which is what `cmux vpn status`
    /// prints, so the gate and the status command can never disagree.
    func tunnelIsUp() -> Bool {
        guard tunnelInterfacePresent() else { return false }
        let expected = tunnelAddresses()
        guard !expected.isEmpty else { return false }
        return !expected.isDisjoint(with: localAddresses())
    }

    /// Refuses the dial if it cannot succeed, otherwise proves the address answers.
    ///
    /// `machine` is the name the error shows people (label, else id).
    /// `urlString` is anything with a host: the `ws://[fd0b::…]:1337/v1/link`
    /// route, an `http://10.16.0.5:6901` desktop URL, a bare `ssh` host.
    func ensureReachable(machine: String, urlString: String) async throws {
        guard let destination = Self.destination(from: urlString) else { return }
        try await ensureReachable(machine: machine, host: destination.host, port: destination.port)
    }

    /// The gate without the probe: refuses a private destination while the
    /// tunnel is down and returns immediately otherwise. For surfaces that open
    /// their own connection and only need the fail-fast verdict, like a browser
    /// pane navigating straight to a forwarded port, where a second handshake
    /// would only slow down the case that already works.
    func ensureRoutable(machine: String, urlString: String) throws {
        guard let destination = Self.destination(from: urlString) else { return }
        guard Self.isPrivateAddress(destination.host), !tunnelIsUp() else { return }
        throw VMClientError.tunnelDown(machine: machine, address: destination.host)
    }

    func ensureReachable(machine: String, host: String, port: Int?) async throws {
        let privateNetwork = Self.isPrivateAddress(host)
        if privateNetwork, !tunnelIsUp() {
            throw VMClientError.tunnelDown(machine: machine, address: host)
        }
        guard let port else { return }
        do {
            try await boundedDial(host: host, port: port)
        } catch DialFailure.refused {
            // The address answers; whatever listens there is the transport's problem.
            return
        } catch is DialFailure {
            throw VMClientError.machineUnreachable(machine: machine, address: host, privateNetwork: privateNetwork)
        }
    }

    /// The dial raced against the deadline; whichever finishes first wins and
    /// the other is cancelled.
    func boundedDial(host: String, port: Int) async throws {
        let dial = self.dial
        let timeout = connectTimeout
        let clock = self.clock
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await dial(host, port) }
            group.addTask {
                try await clock.sleep(for: timeout)
                throw DialFailure.timedOut
            }
            defer { group.cancelAll() }
            try await group.next()
        }
    }

    // MARK: - Address classification

    /// `(host, port)` from anything URL-shaped. IPv6 literals come back without
    /// their brackets; a string with no scheme is treated as a bare host.
    static func destination(from urlString: String) -> (host: String, port: Int?)? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidate = trimmed.contains("://") ? trimmed : "tcp://\(trimmed)"
        guard let components = URLComponents(string: candidate),
              let rawHost = components.host, !rawHost.isEmpty else {
            return nil
        }
        // `URLComponents.host` keeps IPv6 brackets on some OS versions and
        // strips them on others; a zone id (`%en0`) may arrive percent-encoded.
        var host = rawHost
        if host.hasPrefix("["), host.hasSuffix("]") {
            host.removeFirst()
            host.removeLast()
        }
        host = host.removingPercentEncoding ?? host
        return (host.lowercased(), components.port)
    }

    /// Whether `host` can only be reached over a private network: RFC 1918,
    /// CGNAT (`100.64.0.0/10`), link-local, ULA (`fc00::/7`), IPv6 link-local
    /// (`fe80::/10`), their IPv4-mapped forms, and the `.internal` names
    /// `cmux vpn hosts` publishes for those same addresses. Loopback is not
    /// private in this sense: it needs no tunnel. Any other hostname is
    /// assumed public; a wrong guess there only skips the route gate, and the
    /// bounded dial still catches a destination that does not answer.
    static func isPrivateAddress(_ host: String) -> Bool {
        var text = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.hasPrefix("["), text.hasSuffix("]") {
            text.removeFirst()
            text.removeLast()
        }
        if let zone = text.firstIndex(of: "%") {
            text = String(text[..<zone])
        }
        guard !text.isEmpty else { return false }
        if text.hasSuffix(".internal") { return true }
        if let v4 = ipv4Octets(text) { return isPrivateIPv4(v4) }
        if let v6 = ipv6Bytes(text) {
            // ::ffff:a.b.c.d carries an IPv4 address in its low 32 bits.
            if v6[0..<10].allSatisfy({ $0 == 0 }), v6[10] == 0xFF, v6[11] == 0xFF {
                return isPrivateIPv4([v6[12], v6[13], v6[14], v6[15]])
            }
            if v6[0] & 0xFE == 0xFC { return true }               // fc00::/7
            if v6[0] == 0xFE, v6[1] & 0xC0 == 0x80 { return true } // fe80::/10
            return false
        }
        return false
    }

    private static func isPrivateIPv4(_ o: [UInt8]) -> Bool {
        if o[0] == 10 { return true }                                  // 10/8
        if o[0] == 172, (16...31).contains(o[1]) { return true }       // 172.16/12
        if o[0] == 192, o[1] == 168 { return true }                    // 192.168/16
        if o[0] == 100, (64...127).contains(o[1]) { return true }      // 100.64/10
        if o[0] == 169, o[1] == 254 { return true }                    // 169.254/16
        return false
    }

    private static func ipv4Octets(_ text: String) -> [UInt8]? {
        var addr = in_addr()
        guard inet_pton(AF_INET, text, &addr) == 1 else { return nil }
        let raw = UInt32(bigEndian: addr.s_addr)
        return [UInt8(raw >> 24 & 0xFF), UInt8(raw >> 16 & 0xFF), UInt8(raw >> 8 & 0xFF), UInt8(raw & 0xFF)]
    }

    private static func ipv6Bytes(_ text: String) -> [UInt8]? {
        var addr = in6_addr()
        guard inet_pton(AF_INET6, text, &addr) == 1 else { return nil }
        return withUnsafeBytes(of: &addr) { Array($0) }
    }

    // MARK: - Live dial

    /// One TCP handshake through Network.framework. Resolves when the
    /// connection is `.ready`; a `.waiting` state whose error says the
    /// destination has no route fails immediately instead of idling until
    /// the deadline, because that is precisely the tunnel-down signature.
    static func tcpHandshake(host: String, port: Int) async throws {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: max(0, port))) else {
            throw DialFailure.unreachable("invalid port \(port)")
        }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        let settled = CloudLinkFirstValue<Result<Void, DialFailure>>()
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                settled.resolve(.success(()))
                connection.cancel()
            case .failed(let error):
                settled.resolve(.failure(classify(error)))
                connection.cancel()
            case .waiting(let error):
                // Network.framework parks a connection here and retries on its
                // own for anything it deems transient: no route (the tunnel is
                // down), a refused port (the daemon is still booting). One
                // attempt is the whole question this probe asks, so the first
                // verdict is final.
                settled.resolve(.failure(classify(error)))
                connection.cancel()
            case .cancelled:
                settled.resolve(nil)
            default:
                break
            }
        }
        connection.start(queue: .global(qos: .userInitiated))
        let outcome: Result<Void, DialFailure>? = await withTaskCancellationHandler {
            await settled.result
        } onCancel: {
            connection.cancel()
        }
        guard let outcome else { throw CancellationError() }
        try outcome.get()
    }

    private static func classify(_ error: NWError) -> DialFailure {
        switch error {
        case .posix(let code):
            switch code {
            case .ECONNREFUSED:
                return .refused
            case .ENETUNREACH, .EHOSTUNREACH, .ENETDOWN, .EADDRNOTAVAIL, .EHOSTDOWN:
                return .unreachable(String(describing: code))
            case .ETIMEDOUT:
                return .timedOut
            default:
                return .unreachable(String(describing: error))
            }
        case .dns:
            return .unreachable(String(describing: error))
        default:
            return .unreachable(String(describing: error))
        }
    }
}
