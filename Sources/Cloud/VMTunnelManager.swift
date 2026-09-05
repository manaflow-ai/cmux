import CryptoKit
import CmuxSettings
import Darwin
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
/// - the assembled WireGuard config at `~/.cmuxterm/wireguard/<scope>.conf`
///   (0600), with one key and config for each tunnel role.
///
/// The terminal role runs inside the bundled cmux-tui process and needs no
/// system route or privilege. The browser role uses ``CloudTunnelBackend``:
///
/// - **NetworkExtension** — the app-managed path. When release signing
///   carries `com.apple.developer.networking.networkextension` and the bundled
///   `cmuxTunnel.systemextension`, ``CloudTunnelCoordinator`` saves the
///   completed config as a macOS VPN configuration and starts it on demand
///   when the user opens a Cloud browser: no sudo, no command-line tunnel, and
///   no Homebrew. That tunnel reports liveness through `NEVPNStatus`.
/// Builds without that signed capability fail closed for browser access. They
/// never start a privileged command-line fallback.
struct VMTunnelManager: Sendable {
    enum Purpose: String, Sendable {
        case terminal
        case browser
    }

    struct LocalTunnelState: Sendable {
        let endpoint: VMTunnelEndpoint
        /// Path of the written wg-quick config (private key included, 0600).
        let configPath: String
        /// The wg-quick interface name derived from the config filename.
        let interfaceName: String
        /// The same config as text, for the NetworkExtension backend, which
        /// hands it to the system rather than to wg-quick. Never logged.
        let completedConfig: String
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

    /// The config name is scoped to the app/build identity. Stable production
    /// keeps the historical `cmux`
    /// name; nightly, staging, and every tagged DEBUG build get a distinct
    /// deterministic name. The deployment URL is only a fallback for callers
    /// that have no bundle identity. This matters when a production-targeted
    /// tagged DEBUG build and nightly run on one Mac: both can enroll without
    /// overwriting each other's config, key, or device fingerprint.
    let interfaceName: String
    let purpose: Purpose

    let home: URL

    init(
        home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
        interfaceName: String? = nil,
        purpose: Purpose = .browser,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        apiBaseURL: URL = AuthEnvironment.vmAPIBaseURL
    ) {
        self.home = home
        self.purpose = purpose
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

    /// `~/.cmuxterm/wireguard`, 0700, alongside the cmux-tui client state,
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
        let filename = usesLegacyCredentialFiles && purpose == .browser
            ? "private.key"
            : "\(interfaceName).\(purpose.rawValue).private.key"
        return stateDir.appendingPathComponent(filename, isDirectory: false)
    }

    var deviceIDURL: URL {
        let filename = usesLegacyCredentialFiles && purpose == .browser
            ? "device-id"
            : "\(interfaceName).\(purpose.rawValue).device-id"
        return stateDir.appendingPathComponent(filename, isDirectory: false)
    }
    var configURL: URL {
        let filename = usesLegacyCredentialFiles && purpose == .browser
            ? "\(interfaceName).conf"
            : "\(interfaceName).\(purpose.rawValue).conf"
        return stateDir.appendingPathComponent(filename, isDirectory: false)
    }
    /// Whether this build can own the tunnel as a NetworkExtension VPN:
    /// the signed `packet-tunnel-provider-systemextension` capability, the
    /// `system-extension.install` entitlement, and the bundled extension all
    /// present. See ``CloudTunnelBackendSelector`` for the exact rule.
    ///
    /// Reads the signature and the bundle rather than trying to configure a
    /// manager, so an unentitled build never shows the user a doomed VPN
    /// prompt, and a build whose signing dropped the extension never claims a
    /// backend it cannot run.
    static func networkExtensionAvailable() -> Bool {
        CloudTunnelBackendSelector.live().select().isNetworkExtension
    }

    /// The config on disk from the last enrollment, or nil before the first.
    func writtenConfig() -> String? {
        try? String(contentsOf: configURL, encoding: .utf8)
    }

    /// The stable per-build installation device fingerprint, minted on first use.
    /// Distinct from the per-machine cmux-tui fingerprints: this one names this
    /// app/build's membership on the account's network.
    func deviceFingerprint() throws -> String {
        if let existing = storedDeviceFingerprint() { return existing }
        let minted = "mac-" + UUID().uuidString.lowercased()
        try ensureStateDir()
        try write(minted + "\n", to: deviceIDURL)
        return minted
    }

    /// The enrolled role identity already on disk. Status and diagnostics use
    /// this read-only form so checking a revoked tunnel cannot recreate state.
    func storedDeviceFingerprint() -> String? {
        guard let existing = try? String(contentsOf: deviceIDURL, encoding: .utf8) else {
            return nil
        }
        let trimmed = existing.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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
            deviceID: MobileHostIdentity.deviceID(),
            deviceFingerprint: fingerprint,
            tunnelPurpose: purpose.rawValue,
            deviceName: deviceName ?? MobileHostIdentity.baseDisplayName() ?? CloudTuiClientPaths.deviceName(),
            modelIdentifier: Self.modelIdentifier(),
            osVersion: Self.osVersion(),
            architecture: Self.architecture,
            cmuxVersion: MobileHostBuildIdentity.current().appVersion,
            cmuxBuild: MobileHostBuildIdentity.current().appBuild,
            cmuxChannel: Self.cmuxChannel()
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
            interfaceName: interfaceName,
            completedConfig: config
        )
    }

    /// SHA-256 of the config on disk, for status output; nil when there is none.
    func configDigest() -> String? {
        guard let data = try? Data(contentsOf: configURL) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
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

    /// Delete all local secrets for this tunnel role. Provider revoke happens first when online.
    func removeLocalCredentials() {
        for url in [privateKeyURL, deviceIDURL, configURL] {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func modelIdentifier() -> String? {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 1 else { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        let status = bytes.withUnsafeMutableBytes { buffer in
            sysctlbyname("hw.model", buffer.baseAddress, &size, nil, 0)
        }
        guard status == 0 else { return nil }
        return String(cString: bytes)
    }

    private static func osVersion() -> String {
        let value = ProcessInfo.processInfo.operatingSystemVersion
        return "\(value.majorVersion).\(value.minorVersion).\(value.patchVersion)"
    }

    private static var architecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unknown"
        #endif
    }

    private static func cmuxChannel(bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> String {
        let id = bundleIdentifier?.lowercased() ?? ""
        if id.contains("nightly") { return "nightly" }
        if id.contains("staging") { return "staging" }
        if id.hasSuffix(".rc") { return "rc" }
        if id == "com.cmuxterm.app" { return "stable" }
        return "dev"
    }
}
