public import CmuxMobileSSH
public import Foundation

/// The native ("On iPhone") browser's network for an SSH computer.
///
/// Two paths, because iOS never sends loopback destinations to a proxy:
///
/// - **Everything else** goes through a SOCKS5 proxy on the phone
///   (``SSHSocksProxy``, `ssh -D`): each connection leaves from the server
///   and domain names resolve there, so intranet names, LAN addresses, and
///   every port work with the page's real origin.
/// - **`localhost`, `127.0.0.1`, `::1`** bypass any proxy (measured with
///   Network.framework `ProxyConfiguration`), so the phone's own loopback
///   ports stand in for the server's: every port the server listens on at
///   loopback is forwarded from the same port number on the phone. The page
///   keeps its origin (`localhost:3000`) and its requests to other local
///   ports reach the server's.
///
/// Both end with the SSH connection and come back when it reconnects.
extension MobileSSHComputers {
    /// Readies the browser network for a navigation: the proxy, plus the
    /// loopback forwards when the page is on `localhost`. Returns the proxy
    /// port for the browser's data store.
    public func prepareBrowserNetwork(hostID: UUID, loopbackPort: Int?) async throws -> Int {
        browserHosts.insert(hostID)
        let port = try await browserProxyPort(hostID: hostID)
        if let loopbackPort {
            await forwardServerLoopback(hostID: hostID, ensuring: loopbackPort)
        }
        return port
    }

    /// The host's SOCKS proxy port, starting the proxy (and connecting) when
    /// needed. A restarted proxy rebinds its previous port when free.
    public func browserProxyPort(hostID: UUID) async throws -> Int {
        if let proxy = browserProxies[hostID] { return proxy.port }
        if let pending = pendingBrowserProxies[hostID] { return try await pending.value.port }
        let preferred = lastBrowserProxyPorts[hostID]
        let teardown = browserNetworkTeardowns[hostID]
        let task = Task { @MainActor () throws -> SSHSocksProxy in
            await teardown?.value
            let connection = try await self.liveConnection(hostID: hostID)
            let proxy: SSHSocksProxy
            if let preferred, let rebound = try? await SSHSocksProxy.start(over: connection, port: preferred) {
                proxy = rebound
            } else {
                proxy = try await SSHSocksProxy.start(over: connection)
            }
            // The connection may have dropped while the listener started.
            guard self.isCurrentConnection(connection, hostID: hostID) else {
                await proxy.stop()
                throw SSHConnectionError.closed
            }
            return proxy
        }
        pendingBrowserProxies[hostID] = task
        defer { pendingBrowserProxies[hostID] = nil }
        let proxy = try await task.value
        browserProxies[hostID] = proxy
        lastBrowserProxyPorts[hostID] = proxy.port
        return proxy.port
    }

    /// Forwards every loopback port the server listens on (plus `port`) from
    /// the same port on the phone. A phone port that is busy stays as is:
    /// when the server is this same machine (Simulator), the server itself
    /// already owns it, and the page reaches it directly. Another SSH computer's forward on a port is replaced,
    /// since the page being opened now wants this computer's.
    func forwardServerLoopback(hostID: UUID, ensuring port: Int) async {
        await browserNetworkTeardowns[hostID]?.value
        guard let connection = try? await liveConnection(hostID: hostID) else { return }
        let listening: [Int: String]?
        if let result = try? await connection.exec(Self.listeningPortsCommand), result.exitStatus == 0 {
            listening = Self.loopbackListeners(fromNetstat: result.stdoutString)
        } else {
            listening = nil
        }
        // Without a port list, forward the page's port to the server's
        // `localhost`. With one, only ports something listens on, each to
        // the address it listens on, so a forward never points back at the
        // phone's own listener when both are the same machine.
        var targets = listening ?? [:]
        if listening == nil, (1...65_535).contains(port) { targets[port] = "localhost" }
        // Never mirror onto this app's own listeners (proxies, forwards):
        // when the server is this same machine its scan lists them too.
        let ownPorts = Set(browserProxies.values.map(\.port))
            .union(forwardsByHost.values.flatMap { $0.map(\.localPort) })
        targets = targets.filter { !ownPorts.contains($0.key) }
        // The page's own port first, then the rest, lowest first.
        let others = targets.keys.filter { $0 >= 1_024 && $0 != port }.sorted()
        let wanted = ([port].filter { targets[$0] != nil } + others).prefix(Self.maxLoopbackForwards)
        for localPort in wanted {
            guard let target = targets[localPort] else { continue }
            if let existing = loopbackForwards[localPort] {
                if existing.hostID == hostID { continue }
                loopbackForwards[localPort] = nil
                await existing.forward.stop()
            } else if loopbackBusyPorts[hostID]?.contains(localPort) == true {
                continue
            }
            // Network.framework refuses a port any socket holds (IPv4, IPv6,
            // or wildcard), so a same-machine server's port is never shadowed
            // and a forward never loops back into itself.
            guard let forward = try? await SSHLocalPortForward.start(
                over: connection, targetHost: target, targetPort: localPort, localPort: localPort
            ) else {
                loopbackBusyPorts[hostID, default: []].insert(localPort)
                continue
            }
            guard isCurrentConnection(connection, hostID: hostID), loopbackForwards[localPort] == nil else {
                await forward.stop()
                continue
            }
            loopbackForwards[localPort] = (hostID, forward)
        }
    }

    /// Ends the host's proxy and loopback forwards (its connection ended).
    func stopBrowserNetwork(hostID: UUID) {
        pendingBrowserProxies.removeValue(forKey: hostID)?.cancel()
        let proxy = browserProxies.removeValue(forKey: hostID)
        loopbackBusyPorts[hostID] = nil
        let forwards = loopbackForwards.filter { $0.value.hostID == hostID }
        for port in forwards.keys { loopbackForwards[port] = nil }
        let previous = browserNetworkTeardowns[hostID]
        browserNetworkTeardowns[hostID] = Task {
            await previous?.value
            await proxy?.stop()
            for entry in forwards.values { await entry.forward.stop() }
        }
    }

    /// Brings the proxy back after a reconnect when the host's browser was
    /// in use, on the same port, so an open page keeps working.
    func restoreBrowserProxy(hostID: UUID) {
        guard browserHosts.contains(hostID), browserProxies[hostID] == nil else { return }
        Task { _ = try? await browserProxyPort(hostID: hostID) }
    }

    /// Upper bound on forwarded loopback ports per computer.
    nonisolated static let maxLoopbackForwards = 256

    /// Lists TCP listeners on Linux (`ss`, `netstat`) and macOS/BSD (`netstat`).
    nonisolated static let listeningPortsCommand =
        "ss -Hltn 2>/dev/null || netstat -an -p tcp 2>/dev/null || netstat -ltn 2>/dev/null"

    /// Loopback-reachable listeners from `ss`/`netstat` output: port to the
    /// address to connect to (`127.0.0.1` or `::1`). Wildcard listeners are
    /// reached through `127.0.0.1`; listeners on other addresses are skipped.
    nonisolated static func loopbackListeners(fromNetstat output: String) -> [Int: String] {
        var result: [Int: String] = [:]
        for line in output.split(separator: "\n") where line.contains("LISTEN") {
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            // ss: State Recv-Q Send-Q Local Peer; netstat: Proto Recv-Q Send-Q Local Foreign State.
            guard fields.count >= 4 else { continue }
            let local = fields[3]
            // macOS netstat names the family: `tcp6 *.P` is IPv6-only.
            let ipv6Only = fields[0] == "tcp6"
            guard let separator = local.lastIndex(where: { $0 == ":" || $0 == "." }),
                  let port = Int(local[local.index(after: separator)...]), (1...65_535).contains(port) else { continue }
            var address = String(local[..<separator])
            if address.hasPrefix("["), address.hasSuffix("]") { address = String(address.dropFirst().dropLast()) }
            if let percent = address.firstIndex(of: "%") { address = String(address[..<percent]) }
            let target: String?
            switch address {
            case "::1", "0:0:0:0:0:0:0:1":
                target = "::1"
            case "*" where ipv6Only, "::":
                // An IPv6 wildcard may not accept IPv4: reach it on `::1`.
                target = "::1"
            case "*", "0.0.0.0", "", "::ffff:0.0.0.0":
                target = "127.0.0.1"
            default:
                target = address.hasPrefix("127.") ? address : nil
            }
            guard let target else { continue }
            // Prefer IPv4 when a port listens on both.
            if result[port] == nil || target != "::1" { result[port] = target }
        }
        return result
    }
}
