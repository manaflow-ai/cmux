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

        var description: String {
            switch self {
            case .keyStorageFailed(let detail):
                return "Could not store the WireGuard key for this Mac: \(detail)"
            case .configMalformed(let detail):
                return "The tunnel config from the Cloud VM service could not be completed: \(detail)"
            }
        }
    }

    /// Which of this Mac's two tunnel identities a manager instance owns.
    ///
    /// WireGuard binds one key to one live session: the server remembers the
    /// endpoint of the last authenticated sender, so two processes handshaking
    /// with the same key steal each other's traffic. The system interface
    /// (`cmux vpn up`) and the app's in-process hub (`cmux-tui wg hub`) therefore
    /// never share a key; each is its own device on the account's network.
    enum Identity: Sendable, Equatable {
        /// The wg-quick system interface: `cmux.conf`, `private.key`, `mac-<uuid>`.
        case system
        /// The app hub of one app instance, scoped by the canonical instance tag
        /// (``MobileHostIdentity/instanceTag()``, the same tag that owns the debug
        /// socket and cmuxd paths). The stable release (`default`) keeps
        /// `cmux-app.conf`, `app.key`, `mac-<uuid>-app`; every other instance
        /// (`nightly`, `rc`, a tagged DEV build) is suffixed by its tag, so two
        /// builds on one Mac never run two hubs on one WireGuard key, which would
        /// fight over the server-side endpoint and re-key each other on enroll.
        case app(instanceTag: String)

        /// The stable channel's instance tag, which keeps the unscoped names.
        static let releaseInstanceTag = "default"

        /// The app identity of the running instance.
        static func forThisApp() -> Identity {
            .app(instanceTag: MobileHostIdentity.instanceTag())
        }

        /// The scope an instance tag adds: empty for the stable release, else the
        /// tag lowercased with anything outside `[a-z0-9-]` folded to `-`.
        static func appScope(instanceTag: String) -> String {
            let trimmed = instanceTag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if trimmed.isEmpty || trimmed == releaseInstanceTag { return "" }
            let folded = trimmed.map { ch -> Character in
                (ch.isASCII && (ch.isLetter || ch.isNumber)) ? ch : "-"
            }
            var scope = String(folded)
            while scope.contains("--") { scope = scope.replacingOccurrences(of: "--", with: "-") }
            scope = scope.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            return scope.isEmpty ? "unknown" : String(scope.prefix(48))
        }

        /// `-<scope>` for a scoped app identity, empty otherwise.
        var scopeSuffix: String {
            switch self {
            case .system: return ""
            case .app(let instanceTag):
                let scope = Self.appScope(instanceTag: instanceTag)
                return scope.isEmpty ? "" : "-" + scope
            }
        }

        /// The device fingerprint suffix appended to the system fingerprint.
        var fingerprintSuffix: String {
            switch self {
            case .system: return ""
            case .app: return "-app" + scopeSuffix
            }
        }
    }

    /// wg-quick names the interface after the config file, so this is both.
    static let interfaceName = "cmux"

    let home: URL
    let identity: Identity

    init(home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true), identity: Identity = .system) {
        self.home = home
        self.identity = identity
    }

    /// `~/.cmuxterm/wireguard`, 0700 — alongside the cmux-tui client state,
    /// which follows the same file-permission model for its device key.
    var stateDir: URL {
        home.appendingPathComponent(".cmuxterm", isDirectory: true)
            .appendingPathComponent("wireguard", isDirectory: true)
    }

    var privateKeyURL: URL {
        switch identity {
        case .system: return stateDir.appendingPathComponent("private.key", isDirectory: false)
        case .app: return stateDir.appendingPathComponent("app\(identity.scopeSuffix).key", isDirectory: false)
        }
    }
    /// The one per-installation device id both identities derive from; a
    /// reinstall that mints a new one rotates both tunnels together.
    var deviceIDURL: URL { stateDir.appendingPathComponent("device-id", isDirectory: false) }
    var configURL: URL {
        switch identity {
        case .system: return stateDir.appendingPathComponent("\(Self.interfaceName).conf", isDirectory: false)
        case .app: return stateDir.appendingPathComponent("\(Self.interfaceName)-app\(identity.scopeSuffix).conf", isDirectory: false)
        }
    }

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
    /// Mac itself on the account's network. The app identity appends `-app` to
    /// the same minted id, so the two tunnels are visibly one Mac.
    func deviceFingerprint() throws -> String {
        try baseDeviceFingerprint() + identity.fingerprintSuffix
    }

    private func baseDeviceFingerprint() throws -> String {
        if let existing = try? String(contentsOf: deviceIDURL, encoding: .utf8) {
            let trimmed = existing.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        let minted = "mac-" + UUID().uuidString.lowercased()
        try ensureStateDir()
        try write(minted + "\n", to: deviceIDURL)
        return minted
    }

    /// The `AllowedIPs` of the config on disk (the addresses this tunnel routes),
    /// or empty when no config has been written yet.
    func configuredRoutes() -> [String] {
        guard let config = try? String(contentsOf: configURL, encoding: .utf8) else { return [] }
        return Self.allowedIPs(in: config)
    }

    /// The `AllowedIPs =` values in a wg-quick config's `[Peer]` sections, in order.
    static func allowedIPs(in config: String) -> [String] {
        var routes: [String] = []
        var inPeer = false
        for rawLine in config.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inPeer = line.lowercased() == "[peer]"
                continue
            }
            guard inPeer else { continue }
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "allowedips" else { continue }
            for entry in parts[1].split(separator: ",") {
                let value = entry.trimmingCharacters(in: .whitespaces)
                if !value.isEmpty { routes.append(value) }
            }
        }
        return routes
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
