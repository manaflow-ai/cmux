import CryptoKit
import Foundation
import Security

/// This Mac's membership in the user's private Cloud VM network.
///
/// Every Cloud VM the user owns sits on one provider-side private network, and
/// the machines open no public inbound port — so this Mac can only reach their
/// session daemons through a WireGuard tunnel into that network. This type owns
/// the local half of that tunnel:
///
/// - a Curve25519 keypair generated here, whose private half never leaves this
///   Mac (the control plane receives only the public key),
/// - a stable per-installation device fingerprint, so re-enrolling on every
///   launch resolves to the same tunnel and the same address on the network,
/// - the assembled wg-quick config at `~/.cmuxterm/wireguard/cmux.conf` (0600),
///   which is the one artifact both bring-up paths consume.
///
/// Bringing the interface up needs privileges the app process does not have,
/// and there are two backends for it:
///
/// - **wg-quick** (`cmux vpn up`) — the shipping path. The CLI runs
///   `sudo wg-quick up` against the config this manager wrote; sudo in the
///   user's own terminal is the honest privilege prompt.
/// - **NetworkExtension** — the long-term path, pending the
///   `com.apple.developer.networking.networkextension` entitlement. When a
///   build carries it, the app can own the tunnel as a real macOS VPN with no
///   admin prompt. `networkExtensionAvailable` gates that branch at runtime so
///   the same build degrades to the CLI path when the entitlement is absent.
struct VMTunnelManager: Sendable {
    struct LocalTunnelState: Sendable {
        let endpoint: VMTunnelEndpoint
        /// Path of the written wg-quick config (private key included, 0600).
        let configPath: String
        /// The wg-quick interface name derived from the config filename.
        let interfaceName: String
    }

    enum TunnelError: Error, CustomStringConvertible {
        case keyStorageFailed(String)
        case configMalformed(String)
        /// The machine's route lies inside the private network and this Mac's
        /// tunnel is not up, so nothing can reach the daemon until it is.
        case tunnelDown

        var description: String {
            switch self {
            case .keyStorageFailed(let detail):
                return "Could not store the WireGuard key for this Mac: \(detail)"
            case .configMalformed(let detail):
                return "The tunnel config from the Cloud VM service could not be completed: \(detail)"
            case .tunnelDown:
                return String(
                    localized: "cloud.tunnel.down",
                    defaultValue: "This machine is on your private network, but this Mac's tunnel is down. Run `cmux vpn up` in a terminal, then open the machine again."
                )
            }
        }
    }

    /// wg-quick names the interface after the config file, so this is both.
    static let interfaceName = "cmux"

    let home: URL

    init(home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)) {
        self.home = home
    }

    /// `~/.cmuxterm/wireguard`, 0700 — alongside the cmux-tui client state,
    /// which follows the same file-permission model for its device key.
    var stateDir: URL {
        home.appendingPathComponent(".cmuxterm", isDirectory: true)
            .appendingPathComponent("wireguard", isDirectory: true)
    }

    var privateKeyURL: URL { stateDir.appendingPathComponent("private.key", isDirectory: false) }
    var deviceIDURL: URL { stateDir.appendingPathComponent("device-id", isDirectory: false) }
    var configURL: URL { stateDir.appendingPathComponent("\(Self.interfaceName).conf", isDirectory: false) }

    /// wg-quick(8) records the created utun's name here — but on macOS the
    /// file is root-only (0400), so liveness detection must not depend on it;
    /// see `wgQuickInterfaceUp()`.
    var runtimeNameFileURL: URL {
        URL(fileURLWithPath: "/var/run/wireguard/\(Self.interfaceName).name", isDirectory: false)
    }

    /// Whether this build can own the tunnel as a NetworkExtension VPN.
    ///
    /// Reads the signed entitlement rather than trying to configure a manager,
    /// so an unentitled build never shows the user a doomed VPN prompt. Today
    /// no build carries the entitlement; when release signing gains it, this
    /// flips to true with no code change and `cmux vpn up` starts steering to
    /// the app-managed tunnel.
    static func networkExtensionAvailable() -> Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let key = "com.apple.developer.networking.networkextension" as CFString
        guard let raw = SecTaskCopyValueForEntitlement(task, key, nil) else { return false }
        if let capabilities = raw as? [String] {
            return capabilities.contains("packet-tunnel-provider")
        }
        return false
    }

    /// The stable per-installation device fingerprint, minted on first use.
    /// Distinct from the per-machine cmux-tui fingerprints: this one names the
    /// Mac itself on the account's network.
    func deviceFingerprint() throws -> String {
        if let existing = try? String(contentsOf: deviceIDURL, encoding: .utf8) {
            let trimmed = existing.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        let minted = "mac-" + UUID().uuidString.lowercased()
        try ensureStateDir()
        try write(minted + "\n", to: deviceIDURL)
        return minted
    }

    /// The Mac's WireGuard keypair, minted on first use. Returns base64 halves;
    /// only the public one may travel.
    func keypair() throws -> (privateKey: String, publicKey: String) {
        if let existing = try? String(contentsOf: privateKeyURL, encoding: .utf8) {
            let trimmed = existing.trimmingCharacters(in: .whitespacesAndNewlines)
            if let data = Data(base64Encoded: trimmed), data.count == 32,
               let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data) {
                return (trimmed, key.publicKey.rawRepresentation.base64EncodedString())
            }
        }
        let key = Curve25519.KeyAgreement.PrivateKey()
        let privateBase64 = key.rawRepresentation.base64EncodedString()
        try ensureStateDir()
        try write(privateBase64 + "\n", to: privateKeyURL)
        return (privateBase64, key.publicKey.rawRepresentation.base64EncodedString())
    }

    /// Enroll this Mac with the control plane and write the completed config.
    ///
    /// Safe to call on every launch: enrollment is idempotent per device, and
    /// rewriting an unchanged config is harmless. A `rotated` response means
    /// the server replaced the tunnel's keys to match this Mac's current
    /// keypair (a reinstall that minted a new one); the address on the network
    /// is preserved either way.
    func enroll(client: VMClient, deviceName: String? = nil) async throws -> LocalTunnelState {
        let keys = try keypair()
        let fingerprint = try deviceFingerprint()
        let endpoint = try await client.enrollTunnel(
            clientPublicKey: keys.publicKey,
            deviceFingerprint: fingerprint,
            deviceName: deviceName ?? CloudTuiClientPaths.deviceName()
        )
        let config = try Self.completedConfig(endpoint.clientConfig, privateKey: keys.privateKey)
        try ensureStateDir()
        try write(config, to: configURL)
        return LocalTunnelState(
            endpoint: endpoint,
            configPath: configURL.path,
            interfaceName: Self.interfaceName
        )
    }

    /// Whether wg-quick currently has this tunnel up, without privileges.
    ///
    /// wg-quick's own record (`/var/run/wireguard/cmux.name`) is root-only on
    /// macOS, so instead this asks the question the network can answer: does
    /// any interface hold one of the tunnel's own `[Interface] Address`es from
    /// the config this manager wrote? Those are fixed platform-side addresses
    /// unique to the tunnel, so a match is the tunnel and nothing else. A
    /// future NetworkExtension tunnel reports through NEVPNStatus instead.
    func wgQuickInterfaceUp() -> Bool {
        guard let config = try? String(contentsOf: configURL, encoding: .utf8) else { return false }
        let expected = Self.interfaceAddresses(in: config)
        guard !expected.isEmpty else { return false }
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0 else { return false }
        defer { freeifaddrs(addrs) }
        var cursor = addrs
        while let current = cursor {
            if let sa = current.pointee.ifa_addr, let address = Self.numericAddress(sa),
               expected.contains(address) {
                return true
            }
            cursor = current.pointee.ifa_next
        }
        return false
    }

    /// Enrolled on this Mac (a config was written by `cmux vpn up`) but the
    /// tunnel is not up right now: the one state where a private-network
    /// machine is known to be unreachable and the fix is known too.
    var isEnrolledButDown: Bool {
        FileManager.default.fileExists(atPath: configURL.path) && !wgQuickInterfaceUp()
    }

    /// Refuses to dial a route this Mac cannot reach.
    ///
    /// A machine on the user's private network advertises its daemon at a
    /// private address (`ws://[fd7a:…]:1337/v1/link`). Nothing on the Internet
    /// answers there, and dialing it with the tunnel down does not fail, it
    /// hangs: the enrollment stays pending until the link (60 s), the approve
    /// loop (5 min) and the CLI (16 min) give up with "Command timed out".
    /// Every cmux-remote open runs this first so the person reads the cause and
    /// the fix within a second instead.
    func preflight(route: String) throws {
        guard Self.routeRequiresTunnel(route) else { return }
        guard !wgQuickInterfaceUp() else { return }
        throw TunnelError.tunnelDown
    }

    /// Whether the route's host is a private-network address, one only the
    /// tunnel routes: IPv6 unique-local (`fc00::/7`, which Freestyle VPCs
    /// draw from) or RFC 1918 / CGNAT IPv4. Hostnames and public addresses
    /// are reachable without the tunnel. An unparseable route is not this
    /// check's problem, so it reads as reachable and fails downstream as before.
    static func routeRequiresTunnel(_ route: String) -> Bool {
        guard let host = routeHost(route) else { return false }
        return isPrivateNetworkAddress(host)
    }

    /// The host of a `scheme://[v6]:port/path` or `scheme://host:port/path`
    /// route, brackets and port stripped, lowercased.
    static func routeHost(_ route: String) -> String? {
        var rest = Substring(route)
        if let schemeEnd = rest.range(of: "://") {
            rest = rest[schemeEnd.upperBound...]
        }
        if let authorityEnd = rest.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) {
            rest = rest[..<authorityEnd]
        }
        if let at = rest.lastIndex(of: "@") {
            rest = rest[rest.index(after: at)...]
        }
        guard !rest.isEmpty else { return nil }
        if rest.first == "[" {
            guard let close = rest.firstIndex(of: "]") else { return nil }
            let inner = rest[rest.index(after: rest.startIndex)..<close]
            return inner.isEmpty ? nil : inner.lowercased()
        }
        // One colon at most: an IPv4 or hostname with an optional port. A bare
        // IPv6 without brackets is not a valid authority and reads as unknown.
        let colons = rest.filter { $0 == ":" }.count
        if colons > 1 { return nil }
        let host = colons == 1 ? rest[..<rest.firstIndex(of: ":")!] : rest
        return host.isEmpty ? nil : host.lowercased()
    }

    static func isPrivateNetworkAddress(_ host: String) -> Bool {
        var v6 = in6_addr()
        if inet_pton(AF_INET6, host, &v6) == 1 {
            // fc00::/7: the unique-local block the private network is addressed from.
            let first = withUnsafeBytes(of: &v6) { $0[0] }
            return (first & 0xfe) == 0xfc
        }
        var v4 = in_addr()
        if inet_pton(AF_INET, host, &v4) == 1 {
            let value = UInt32(bigEndian: v4.s_addr)
            let a = UInt8(truncatingIfNeeded: value >> 24)
            let b = UInt8(truncatingIfNeeded: value >> 16)
            if a == 10 { return true }                              // 10.0.0.0/8
            if a == 172, (16...31).contains(b) { return true }      // 172.16.0.0/12
            if a == 192, b == 168 { return true }                   // 192.168.0.0/16
            if a == 100, (64...127).contains(b) { return true }     // 100.64.0.0/10
            return false
        }
        return false
    }

    /// The `Address =` values in a wg-quick config's `[Interface]` section,
    /// with their prefix lengths stripped (`100.64.0.1/32` → `100.64.0.1`).
    static func interfaceAddresses(in config: String) -> Set<String> {
        var addresses = Set<String>()
        var inInterface = false
        for rawLine in config.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inInterface = line.lowercased() == "[interface]"
                continue
            }
            guard inInterface else { continue }
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "address" else { continue }
            for entry in parts[1].split(separator: ",") {
                let value = entry.trimmingCharacters(in: .whitespaces)
                let bare = value.split(separator: "/", maxSplits: 1).first.map(String.init) ?? value
                if !bare.isEmpty { addresses.insert(bare.lowercased()) }
            }
        }
        return addresses
    }

    private static func numericAddress(_ sa: UnsafeMutablePointer<sockaddr>) -> String? {
        switch Int32(sa.pointee.sa_family) {
        case AF_INET:
            var addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &addr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
            return String(cString: buffer)
        case AF_INET6:
            var addr = sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            guard inet_ntop(AF_INET6, &addr, &buffer, socklen_t(INET6_ADDRSTRLEN)) != nil else { return nil }
            return String(cString: buffer).lowercased()
        default:
            return nil
        }
    }

    /// Fill the blank `PrivateKey` line the server left in the config.
    /// The server-issued config is otherwise complete and final.
    static func completedConfig(_ config: String, privateKey: String) throws -> String {
        var lines = config.components(separatedBy: "\n")
        if let index = lines.firstIndex(where: { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.lowercased().hasPrefix("privatekey")
        }) {
            lines[index] = "PrivateKey = \(privateKey)"
            return lines.joined(separator: "\n")
        }
        // No PrivateKey line at all: insert directly under [Interface].
        guard let interfaceIndex = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces).lowercased() == "[interface]"
        }) else {
            throw TunnelError.configMalformed("no [Interface] section in server config")
        }
        lines.insert("PrivateKey = \(privateKey)", at: interfaceIndex + 1)
        return lines.joined(separator: "\n")
    }

    private func ensureStateDir() throws {
        try FileManager.default.createDirectory(
            at: stateDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    private func write(_ content: String, to url: URL) throws {
        guard let data = content.data(using: .utf8) else {
            throw TunnelError.keyStorageFailed("could not encode \(url.lastPathComponent)")
        }
        do {
            try data.write(to: url, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            throw TunnelError.keyStorageFailed("\(url.path): \(error.localizedDescription)")
        }
    }
}
