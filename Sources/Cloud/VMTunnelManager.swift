import CryptoKit
import CmuxSettings
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
/// - a stable per-build installation device fingerprint, so re-enrolling on
///   every launch resolves to the same tunnel and the same address on the
///   network,
/// - the assembled wg-quick config at `~/.cmuxterm/wireguard/<scope>.conf`
///   (0600), which is the one artifact both bring-up paths consume.
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
        case configChangedWhileApplying(expected: String, actual: String?)

        var description: String {
            switch self {
            case .keyStorageFailed(let detail):
                return "Could not store the WireGuard key for this Mac: \(detail)"
            case .configMalformed(let detail):
                return "The tunnel config from the Cloud VM service could not be completed: \(detail)"
            case .configChangedWhileApplying:
                return "The tunnel config changed while it was being applied; run `cmux vpn up` again."
            }
        }
    }

    /// The interface name — and, since wg-quick derives them from it, the
    /// config, applied-record and runtime-name file names — is scoped to the
    /// app/build identity. Stable production keeps the historical `cmux`
    /// name; nightly, staging, and every tagged DEBUG build get a distinct
    /// deterministic name. The deployment URL is only a fallback for callers
    /// that have no bundle identity. This matters when a production-targeted
    /// tagged DEBUG build and nightly run on one Mac: both can enroll without
    /// overwriting each other's config, key, or device fingerprint.
    let interfaceName: String

    let home: URL

    init(
        home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
        interfaceName: String? = nil,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        apiBaseURL: URL = AuthEnvironment.vmAPIBaseURL
    ) {
        self.home = home
        self.interfaceName = interfaceName ?? Self.interfaceName(
            bundleIdentifier: bundleIdentifier,
            environment: environment,
            apiBaseURL: apiBaseURL
        )
    }

    /// Returns the interface name for a concrete app/build identity.
    ///
    /// The bundle identifier is the durable identity because deployment URLs
    /// are not: a tagged DEBUG bundle can point at localhost today and
    /// `https://cmux.com` tomorrow. Names are limited to 15 characters, the
    /// maximum accepted by wg-quick on macOS. The optional environment is used
    /// for the base DEBUG bundle, whose launch tag is otherwise only present in
    /// `CMUX_TAG`.
    static func interfaceName(
        bundleIdentifier: String?,
        environment: [String: String] = [:],
        apiBaseURL: URL
    ) -> String {
        let normalizedBundleID = normalizedBundleIdentifier(bundleIdentifier)
        let effectiveBundleID = effectiveBundleIdentifier(
            bundleIdentifier: normalizedBundleID,
            environment: environment
        )

        guard let effectiveBundleID else {
            return interfaceName(forAPIBaseURL: apiBaseURL)
        }

        let variant = SocketPathMarkerFiles.variant(
            bundleIdentifier: effectiveBundleID,
            environment: environment
        )
        switch variant {
        case .stable:
            if effectiveBundleID == SocketPathMarkerFiles.stableBundleIdentifier {
                return "cmux"
            }
            if effectiveBundleID == "\(SocketPathMarkerFiles.stableBundleIdentifier).rc" {
                return "cmux-rc"
            }
            return scopedInterfaceName(prefix: "cmux-x", identity: effectiveBundleID, hashLength: 8)
        case .nightly(let slug):
            if effectiveBundleID == SocketPathMarkerFiles.nightlyBundleIdentifier, slug == nil {
                return "cmux-nightly"
            }
            return scopedInterfaceName(prefix: "cmux-n", identity: effectiveBundleID, hashLength: 8)
        case .staging(let slug):
            if effectiveBundleID == SocketPathMarkerFiles.stagingBundleIdentifier, slug == nil {
                return "cmux-staging"
            }
            return scopedInterfaceName(prefix: "cmux-s", identity: effectiveBundleID, hashLength: 8)
        case .dev(let slug):
            let rawTag = effectiveBundleID == SocketPathMarkerFiles.defaultBaseDebugBundleIdentifier
                ? normalizedEnvironmentValue(environment["CMUX_TAG"])?.lowercased()
                : nil
            if effectiveBundleID == SocketPathMarkerFiles.defaultBaseDebugBundleIdentifier,
               slug == nil,
               rawTag == nil {
                return "cmux-dev"
            }
            let identity = rawTag.map { "\(effectiveBundleID)|\($0)" } ?? effectiveBundleID
            return scopedInterfaceName(prefix: "cmux-dev", identity: identity, hashLength: 6)
        }
    }

    /// Compatibility fallback for code that only knows the deployment URL.
    /// New app code should use ``interfaceName(bundleIdentifier:environment:apiBaseURL:)``.
    static func interfaceName(forAPIBaseURL url: URL) -> String {
        legacyInterfaceName(forAPIBaseURL: url)
    }

    /// The URL-only mapping retained for old callers and pre-build-identity
    /// state. It must stay deterministic while the bundle-aware path above
    /// remains the production source of tunnel isolation.
    private static func legacyInterfaceName(forAPIBaseURL url: URL) -> String {
        let host = (url.host ?? "").lowercased()
        if host.isEmpty || host == "cmux.com" || host.hasSuffix(".cmux.com") { return "cmux" }
        if host == "localhost" || host == "127.0.0.1" || host == "::1" { return "cmux-local" }
        if host.contains("staging") { return "cmux-staging" }
        return "cmux-dev"
    }

    private static func normalizedBundleIdentifier(_ value: String?) -> String? {
        normalizedEnvironmentValue(value)?.lowercased()
    }

    private static func normalizedEnvironmentValue(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func effectiveBundleIdentifier(
        bundleIdentifier: String?,
        environment: [String: String]
    ) -> String? {
        let environmentBundleID = normalizedBundleIdentifier(environment["CMUX_BUNDLE_ID"])
        guard let bundleIdentifier else { return environmentBundleID }

        // A directly-launched base DEBUG executable can carry the tag only in
        // its environment. Prefer that more-specific identity, but never let
        // an ambient environment override a concrete stable/nightly bundle.
        if bundleIdentifier == SocketPathMarkerFiles.defaultBaseDebugBundleIdentifier,
           let environmentBundleID,
           environmentBundleID.hasPrefix(bundleIdentifier + ".") {
            return environmentBundleID
        }
        return bundleIdentifier
    }

    private static func scopedInterfaceName(prefix: String, identity: String, hashLength: Int) -> String {
        let digest = SHA256.hash(data: Data(identity.utf8))
        let hash = digest
            .prefix(hashLength / 2 + hashLength % 2)
            .map { String(format: "%02x", $0) }
            .joined()
            .prefix(hashLength)
        let name = "\(prefix)-\(hash)"
        // Prefixes and lengths above are constants chosen to satisfy wg-quick's
        // 15-byte interface limit. Keep this assertion close to the invariant
        // so a future prefix change cannot silently produce an unusable config.
        assert(name.utf8.count <= 15)
        return String(name)
    }

    /// `~/.cmuxterm/wireguard`, 0700 — alongside the cmux-tui client state,
    /// which follows the same file-permission model for its device key.
    var stateDir: URL {
        home.appendingPathComponent(".cmuxterm", isDirectory: true)
            .appendingPathComponent("wireguard", isDirectory: true)
    }

    /// Stable production retains the pre-isolation filenames so an existing
    /// shipping tunnel keeps working. Every other interface gets credentials
    /// of its own; sharing the old `private.key`/`device-id` would let one
    /// build rotate the provider peer underneath another build.
    private var usesLegacyCredentialFiles: Bool { interfaceName == "cmux" }

    var privateKeyURL: URL {
        let filename = usesLegacyCredentialFiles ? "private.key" : "\(interfaceName).private.key"
        return stateDir.appendingPathComponent(filename, isDirectory: false)
    }

    var deviceIDURL: URL {
        let filename = usesLegacyCredentialFiles ? "device-id" : "\(interfaceName).device-id"
        return stateDir.appendingPathComponent(filename, isDirectory: false)
    }
    var configURL: URL { stateDir.appendingPathComponent("\(interfaceName).conf", isDirectory: false) }

    /// wg-quick(8) records the created utun's name here. On macOS the file is
    /// root-only (0400), so its contents are out of reach, but its EXISTENCE is
    /// visible — and that is what tells this tunnel apart from another
    /// environment's in `wgQuickInterfaceUp()`.
    var runtimeNameFileURL: URL {
        URL(fileURLWithPath: "/var/run/wireguard/\(interfaceName).name", isDirectory: false)
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

    /// The stable per-build installation device fingerprint, minted on first use.
    /// Distinct from the per-machine cmux-tui fingerprints: this one names this
    /// app/build's membership on the account's network.
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
        // The provider may return broad 10/8 and fd00::/8 routes. Narrow them
        // to this owner's network so production and Dev interfaces can install
        // their routes simultaneously without colliding.
        let allowedIPs = [endpoint.networkCidr, endpoint.networkCidrV6]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let config = try Self.completedConfig(
            endpoint.clientConfig,
            privateKey: keys.privateKey,
            allowedIPs: allowedIPs
        )
        try ensureStateDir()
        try write(config, to: configURL)
        return LocalTunnelState(
            endpoint: endpoint,
            configPath: configURL.path,
            interfaceName: interfaceName
        )
    }

    /// Which config is actually up. Liveness alone cannot tell enrollments
    /// apart: every enrollment gives this Mac the same tunnel-side address, so
    /// an interface left up for another account — or for keys the server has
    /// since rotated — looks "up" while carrying the wrong peer, and `cmux vpn
    /// up` used to answer "already up" and change nothing. `vpn up` therefore
    /// records the digest of the config it brought up, `vpn down` clears it,
    /// and `isStale()` compares that record with the config on disk.
    var appliedDigestURL: URL { stateDir.appendingPathComponent("\(interfaceName).applied", isDirectory: false) }

    /// SHA-256 of the config on disk; nil when there is none.
    func configDigest() -> String? {
        guard let data = try? Data(contentsOf: configURL) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The digest of the config `cmux vpn up` last brought up; nil when unknown.
    func appliedDigest() -> String? {
        guard let text = try? String(contentsOf: appliedDigestURL, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// `applied: true` after wg-quick brought the current config up, `false`
    /// after the interface was taken down.
    func recordApplied(_ applied: Bool, expectedDigest: String? = nil) throws {
        guard applied else {
            try? FileManager.default.removeItem(at: appliedDigestURL)
            return
        }
        guard let digest = configDigest() else {
            throw TunnelError.configMalformed("no tunnel config to record as applied")
        }
        if let expectedDigest, digest != expectedDigest {
            throw TunnelError.configChangedWhileApplying(expected: expectedDigest, actual: digest)
        }
        try ensureStateDir()
        try write(digest + "\n", to: appliedDigestURL)
    }

    /// Up, but not with the config on disk: another enrollment, rotated keys,
    /// or a tunnel brought up before this record existed (treated as stale
    /// once, so the next `vpn up` re-applies and records it).
    func isStale() -> Bool {
        Self.isStale(interfaceUp: wgQuickInterfaceUp(), appliedDigest: appliedDigest(), configDigest: configDigest())
    }

    static func isStale(interfaceUp: Bool, appliedDigest: String?, configDigest: String?) -> Bool {
        guard interfaceUp, let configDigest else { return false }
        return appliedDigest != configDigest
    }

    /// Why a private-network route cannot work right now — the line the
    /// sidebar shows ahead of the raw link error — or nil when the tunnel is
    /// up with the current enrollment.
    func privateRouteBlocker() -> String? {
        let up = wgQuickInterfaceUp()
        return Self.privateRouteBlocker(interfaceUp: up, stale: up && isStale())
    }

    static func privateRouteBlocker(interfaceUp: Bool, stale: Bool) -> String? {
        if !interfaceUp {
            return String(
                localized: "cloudTree.link.tunnelDown",
                defaultValue: "This Mac's tunnel to your Cloud VM network is down \u{2014} run `cmux vpn up`."
            )
        }
        if stale {
            return String(
                localized: "cloudTree.link.tunnelStale",
                defaultValue: "This Mac's tunnel is up for a different enrollment \u{2014} run `cmux vpn up` to switch it."
            )
        }
        return nil
    }

    /// Whether wg-quick currently has this tunnel up, without privileges.
    ///
    /// Two facts are required: wg-quick's root-owned marker for this interface
    /// exists, and some interface holds one of the `[Interface] Address`es from
    /// this config. The marker separates this build's tunnel from another
    /// enrollment (all enrollments use the same tunnel-side address); the
    /// address check prevents a stale marker after a crash from claiming that
    /// an interface is live. A future NetworkExtension tunnel reports through
    /// NEVPNStatus instead.
    func wgQuickInterfaceUp() -> Bool {
        guard FileManager.default.fileExists(atPath: runtimeNameFileURL.path) else { return false }
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

    /// Fill the blank `PrivateKey` line the server left in the config and,
    /// when supplied, narrow the peer's routes to this network.
    static func completedConfig(
        _ config: String,
        privateKey: String,
        allowedIPs: [String] = []
    ) throws -> String {
        var lines = config.components(separatedBy: "\n")
        func key(of line: String) -> String {
            line.split(separator: "=", maxSplits: 1)
                .first?
                .trimmingCharacters(in: .whitespaces)
                .lowercased() ?? ""
        }
        if let index = lines.firstIndex(where: { key(of: $0) == "privatekey" }) {
            lines[index] = "PrivateKey = \(privateKey)"
        } else {
            // No PrivateKey line at all: insert directly under [Interface].
            guard let interfaceIndex = lines.firstIndex(where: {
                $0.trimmingCharacters(in: .whitespaces).lowercased() == "[interface]"
            }) else {
                throw TunnelError.configMalformed("no [Interface] section in server config")
            }
            lines.insert("PrivateKey = \(privateKey)", at: interfaceIndex + 1)
        }
        if !allowedIPs.isEmpty {
            let routes = "AllowedIPs = \(allowedIPs.joined(separator: ", "))"
            if let index = lines.firstIndex(where: { key(of: $0) == "allowedips" }) {
                lines[index] = routes
            } else if let peerIndex = lines.firstIndex(where: {
                $0.trimmingCharacters(in: .whitespaces).lowercased() == "[peer]"
            }) {
                lines.insert(routes, at: peerIndex + 1)
            } else {
                throw TunnelError.configMalformed("no [Peer] section in server config")
            }
        }
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
