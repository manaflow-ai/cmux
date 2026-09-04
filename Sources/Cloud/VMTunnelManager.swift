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
/// - **wg-quick** (`cmux vpn up`) — the shipping path. Run the CLI as the
///   signed-in user; it invokes `sudo wg-quick up` against the config this
///   manager wrote while preserving that user's build-scoped app socket.
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

    /// A small, non-secret marker written by this config's `PostUp` hook with
    /// wg-quick's actual `utunN` name. The stock `.name` file is root-only, so
    /// its contents cannot be read by the app; this companion marker makes the
    /// scope-to-interface association exact even when two sockets are created
    /// in the same second. It is removed by the matching `PreDown` hook.
    var runtimeInterfaceMetadataURL: URL {
        URL(fileURLWithPath: "/var/run/wireguard/\(interfaceName).cmux-runtime", isDirectory: false)
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
        // Route only this network's own prefixes. The platform's config routes
        // all of 10.0.0.0/8 and fd00::/8, which is fine for one tunnel but
        // overlaps unrelated account networks. Each network is a /24 (and a
        // /64) the enrollment reports; `completedConfig` installs those as
        // interface-scoped routes so a second build can use the same network.
        let networkRoutes = [endpoint.networkCidr, endpoint.networkCidrV6]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        // Older control-plane responses may not include the nested `network`
        // object even though the provider already returned its precise route
        // list. Keep those responses safe for concurrent builds too: use the
        // provider routes as a fallback, and fill only a missing address family
        // when the network wrapper is partial.
        let hasIPv4NetworkRoute = networkRoutes.contains { !$0.contains(":") }
        let hasIPv6NetworkRoute = networkRoutes.contains { $0.contains(":") }
        let allowedIPs = networkRoutes + endpoint.routes.filter { route in
            let isIPv6 = route.contains(":")
            return isIPv6 ? !hasIPv6NetworkRoute : !hasIPv4NetworkRoute
        }
        let config = try Self.completedConfig(
            endpoint.clientConfig,
            privateKey: keys.privateKey,
            allowedIPs: allowedIPs,
            runtimeMetadataPath: runtimeInterfaceMetadataURL.path
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

    /// Whether wg-quick currently has THIS tunnel up, without privileges.
    ///
    /// Two facts, both required: wg-quick's own record for this interface name
    /// exists (`/var/run/wireguard/<name>.name`, root-only but visible), and
    /// the matching `utunN` socket is live and holds one of the tunnel's own
    /// `[Interface] Address`es from the config this manager wrote. The name
    /// file's contents are root-only on macOS, so its mtime/size are matched
    /// against the socket files exactly as `wg-quick` does internally. This
    /// keeps a stale marker for one scope from borrowing another scope's
    /// identical tunnel-side address. A future NetworkExtension tunnel reports
    /// through NEVPNStatus instead.
    func wgQuickInterfaceUp() -> Bool {
        guard let config = try? String(contentsOf: configURL, encoding: .utf8) else { return false }
        var metadataProbe = stat()
        let metadataResult = lstat(runtimeInterfaceMetadataURL.path, &metadataProbe)
        let metadataErrno = errno
        let runtimeInterfaceName: String?
        if metadataResult == 0 {
            // A present-but-invalid companion is evidence of a stale or
            // interrupted scoped bring-up. Do not fall back to lossy inference
            // and risk borrowing another scope's reused utun number.
            runtimeInterfaceName = Self.readRuntimeInterfaceName(
                from: runtimeInterfaceMetadataURL,
                markerURL: runtimeNameFileURL
            )
        } else if metadataErrno == ENOENT {
            // Configs written before the companion marker was introduced use
            // the stock wg-quick timestamp/size inference instead.
            runtimeInterfaceName = Self.runtimeInterfaceName(for: runtimeNameFileURL)
        } else {
            runtimeInterfaceName = nil
        }
        guard let runtimeInterfaceName else { return false }
        return Self.interfaceIsUp(
            runtimeNamePresent: true,
            runtimeInterfaceName: runtimeInterfaceName,
            config: config,
            liveInterfaceAddressesByName: Self.currentInterfaceAddressesByName()
        )
    }

    /// Reads and validates the user-readable companion marker written by the
    /// config's privileged `PostUp` hook. Invalid or stale contents fall back
    /// to the stock wg-quick marker inference instead of being trusted.
    private static func readRuntimeInterfaceName(from metadataURL: URL, markerURL: URL) -> String? {
        var metadataInfo = stat()
        guard lstat(metadataURL.path, &metadataInfo) == 0,
              (metadataInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              metadataInfo.st_size > 0,
              metadataInfo.st_size <= 64,
              let raw = try? String(contentsOf: metadataURL, encoding: .utf8) else { return nil }
        let fields = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
        guard fields.count == 2,
              let interface = fields.first.map(String.init),
              interface.range(of: #"^utun[0-9]+$"#, options: .regularExpression) != nil,
              let expectedInode = fields.last.flatMap({ UInt64(String($0)) }),
              expectedInode > 0 else { return nil }

        // A stale companion file can survive a killed wg-quick process, and
        // Darwin may reuse the same utun number later. Require the companion,
        // wg-quick's root marker, and the socket to belong to one creation
        // window before trusting the readable value.
        var markerInfo = stat()
        guard lstat(markerURL.path, &markerInfo) == 0,
              (markerInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else { return nil }
        var socketInfo = stat()
        let socketURL = metadataURL
            .deletingLastPathComponent()
            .appendingPathComponent("\(interface).sock", isDirectory: false)
        guard lstat(socketURL.path, &socketInfo) == 0,
              (socketInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFSOCK),
              UInt64(socketInfo.st_ino) == expectedInode else { return nil }
        let metadataTime = metadataInfo.st_mtimespec.tv_sec
        let markerTime = markerInfo.st_mtimespec.tv_sec
        let socketTime = socketInfo.st_mtimespec.tv_sec
        // The companion is written by the final PostUp hook, after wg-quick
        // creates both the root marker and the socket. A bounded monotonic
        // ordering rejects a stale file even when Darwin reuses the same utunN,
        // while allowing route setup to take longer than two seconds.
        guard metadataTime >= markerTime,
              metadataTime >= socketTime,
              metadataTime - markerTime <= 60 else { return nil }
        return interface
    }

    /// Combines the two unprivileged liveness signals used by ``wgQuickInterfaceUp``.
    ///
    /// Keeping this decision pure gives tests a deterministic way to cover the
    /// root-owned marker requirement without creating files under `/var/run`.
    static func interfaceIsUp(
        runtimeNamePresent: Bool,
        runtimeInterfaceName: String?,
        config: String,
        liveInterfaceAddressesByName: [String: Set<String>]
    ) -> Bool {
        guard runtimeNamePresent else { return false }
        guard let runtimeInterfaceName,
              let liveInterfaceAddresses = liveInterfaceAddressesByName[runtimeInterfaceName] else {
            return false
        }
        let expected = interfaceAddresses(in: config)
        guard !expected.isEmpty else { return false }
        return !expected.isDisjoint(with: liveInterfaceAddresses)
    }

    /// Finds the actual `utunN` associated with a scope marker.
    ///
    /// `wireguard-go` writes the scope marker and its socket in the same
    /// bring-up operation. Their modification times are within two seconds —
    /// the invariant used by `wg-quick`'s own `get_real_interface()` — while
    /// the marker byte count also identifies the interface when adjacent
    /// sockets are created in the same second. Ambiguous matches fail closed.
    private static func runtimeInterfaceName(for markerURL: URL) -> String? {
        var markerInfo = stat()
        guard lstat(markerURL.path, &markerInfo) == 0,
              (markerInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            return nil
        }

        let directoryURL = markerURL.deletingLastPathComponent()
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        let markerModificationTime = markerInfo.st_mtimespec.tv_sec
        let markerByteCount = markerInfo.st_size
        var matches: [String] = []
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let filename = entry.lastPathComponent
            guard filename.hasPrefix("utun"), filename.hasSuffix(".sock") else { continue }
            let interface = String(filename.dropLast(".sock".count))
            guard interface.count > "utun".count,
                  interface.dropFirst("utun".count).allSatisfy(\.isNumber) else { continue }
            var socketInfo = stat()
            guard lstat(entry.path, &socketInfo) == 0,
                  (socketInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFSOCK) else {
                continue
            }
            let difference = socketInfo.st_mtimespec.tv_sec - markerModificationTime
            guard abs(difference) < 2 else { continue }
            matches.append(interface)
        }

        return Self.selectRuntimeInterface(
            markerByteCount: markerByteCount,
            candidates: matches
        )
    }

    /// Selects one timestamp-matched `utunN` only when its marker-size invariant
    /// also agrees. A stale marker must never borrow a newly-created socket just
    /// because its own socket disappeared during the two-second timestamp window.
    static func selectRuntimeInterface(markerByteCount: Int64, candidates: [String]) -> String? {
        let sizedMatches = candidates.filter { interface in
            // wireguard-go writes the interface name followed by a newline;
            // require that exact size so a stale marker cannot match a
            // different interface whose name happens to have the same length.
            markerByteCount == Int64(interface.utf8.count + 1)
        }
        return sizedMatches.count == 1 ? sizedMatches[0] : nil
    }

    /// Numeric addresses currently assigned to each local interface.
    private static func currentInterfaceAddressesByName() -> [String: Set<String>] {
        var addresses: [String: Set<String>] = [:]
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0 else { return addresses }
        defer { freeifaddrs(addrs) }
        var cursor = addrs
        while let current = cursor {
            if let sa = current.pointee.ifa_addr,
               let address = Self.numericAddress(sa),
               let namePointer = current.pointee.ifa_name {
                let name = String(cString: namePointer)
                addresses[name, default: []].insert(address)
            }
            cursor = current.pointee.ifa_next
        }
        return addresses
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
