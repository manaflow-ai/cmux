import Foundation

/// The protocol an embedded-browser proxy speaks.
///
/// Mirrors the two forward-proxy flavors `Network.framework`'s
/// `ProxyConfiguration` can express for a `WKWebsiteDataStore`: SOCKSv5 and
/// HTTP CONNECT. ``off`` means cmux applies no proxy of its own.
public enum BrowserProxyType: String, CaseIterable, Sendable, Equatable, SettingCodable {
    /// No cmux-managed browser proxy. The embedded browser keeps its default
    /// behavior — on a local pane that still mirrors an active macOS system
    /// proxy for the loopback fix (https://github.com/manaflow-ai/cmux/issues/5888).
    case off
    /// A SOCKSv5 proxy (`ProxyConfiguration(socksv5Proxy:)`).
    case socks5
    /// An HTTP CONNECT proxy (`ProxyConfiguration(httpCONNECTProxy:)`).
    case httpConnect

    /// Resolves a loosely-typed string to a known type, defaulting to ``off``.
    ///
    /// Unknown or misspelled values resolve to ``off`` so a typo never crashes
    /// config loading or silently routes traffic somewhere unexpected. Accepts
    /// common aliases and URL schemes so both the cmux.json `type` field and the
    /// `CMUX_BROWSER_PROXY` URL scheme map onto the same set.
    public init(lenient raw: String) {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "socks5", "socks", "socksv5", "socks-5", "socks_5":
            self = .socks5
        case "httpconnect", "http-connect", "http_connect", "connect", "http", "https":
            self = .httpConnect
        default:
            self = .off
        }
    }
}

/// A user-configured proxy for the embedded browser, read from `cmux.json`
/// (`browser.proxy`) or the `CMUX_BROWSER_PROXY` environment variable.
///
/// Applies to local browser panes only. Remote-workspace panes keep routing
/// through their workspace tunnel; a user proxy never overrides that. When no
/// usable proxy is configured (``isEnabled`` is `false`) the pane falls back to
/// its existing behavior, including the system-proxy mirror.
///
/// Decoding is lenient: every field is optional with a safe default and `port`
/// accepts a number or a numeric string, so a partial or slightly-wrong object
/// still loads as a (possibly disabled) configuration rather than failing the
/// whole config file.
///
/// Credentials are never sourced from `cmux.json`: the JSON coding deliberately
/// drops `username`/`password` on both decode and encode so a proxy password
/// can't leak into the shared, user-editable, copyable config (the same secret
/// boundary the package keeps for `automation.socketPassword` via the secret
/// store). Authenticated proxies pass credentials only through the
/// `CMUX_BROWSER_PROXY` environment override (`socks5://user:pass@host:port`),
/// which populates ``username``/``password`` via ``parse(environmentValue:)``.
public struct BrowserProxyConfiguration: Sendable, Equatable, Codable, SettingCodable {
    /// The proxy protocol, or ``BrowserProxyType/off`` to apply no proxy.
    public let type: BrowserProxyType
    /// Proxy server hostname or IP (e.g. `127.0.0.1`).
    public let host: String
    /// Proxy server TCP port (1...65535 when enabled).
    public let port: Int
    /// Username for an authenticated proxy, or empty. Only set from the
    /// `CMUX_BROWSER_PROXY` env override; never read from `cmux.json`.
    public let username: String
    /// Password for an authenticated proxy, or empty. Only set from the
    /// `CMUX_BROWSER_PROXY` env override; never read from or written to
    /// `cmux.json`.
    public let password: String
    /// Hostname suffixes that connect directly instead of through the proxy.
    public let bypass: [String]

    /// The environment variable that overrides the cmux.json proxy.
    public static let environmentVariableName = "CMUX_BROWSER_PROXY"

    /// The "no proxy" configuration, also the default when the key is absent.
    public static let disabled = BrowserProxyConfiguration(
        type: .off, host: "", port: 0, username: "", password: "", bypass: []
    )

    /// Memberwise initializer.
    public init(
        type: BrowserProxyType,
        host: String,
        port: Int,
        username: String,
        password: String,
        bypass: [String]
    ) {
        self.type = type
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.bypass = bypass
    }

    /// The host with surrounding whitespace removed.
    public var trimmedHost: String {
        host.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True when the configuration names a usable proxy: an enabled type, a
    /// non-empty host, and a port in 1...65535.
    public var isEnabled: Bool {
        type != .off && !trimmedHost.isEmpty && (1...65535).contains(port)
    }

    /// True when authenticated-proxy credentials are present.
    public var hasCredentials: Bool {
        !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The user bypass entries normalized to hostname suffixes: trimmed,
    /// lowercased, with a leading `*.` / `.` stripped, and blanks/duplicates
    /// removed. Matches the normalization the system-proxy mirror applies to
    /// the macOS bypass list so both proxy sources speak the same exclusion
    /// vocabulary (a suffix `local` covers `*.local`).
    public var normalizedBypassDomains: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in bypass {
            var entry = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if entry.hasPrefix("*.") { entry.removeFirst(2) }
            while entry.hasPrefix(".") { entry.removeFirst() }
            guard !entry.isEmpty else { continue }
            if seen.insert(entry).inserted { result.append(entry) }
        }
        return result
    }

    // MARK: - Resolution

    /// The effective configuration after applying the `CMUX_BROWSER_PROXY`
    /// override on top of the cmux.json value.
    ///
    /// The environment variable wins whenever it is set and non-empty. An
    /// unparseable env value is ignored so a typo cannot silently disable a
    /// working file proxy — the file configuration still applies.
    public static func resolved(
        fileConfiguration: BrowserProxyConfiguration,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> BrowserProxyConfiguration {
        guard let raw = environment[environmentVariableName],
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return fileConfiguration
        }
        return parse(environmentValue: raw) ?? fileConfiguration
    }

    /// Parses a `CMUX_BROWSER_PROXY` value of the form
    /// `scheme://[user:pass@]host:port` (e.g. `socks5://127.0.0.1:1080`), or a
    /// bare disable keyword (`off`, `none`, `disabled`, `direct`).
    ///
    /// Returns `nil` when the value is neither — callers then fall back to the
    /// cmux.json configuration. A parsed value carries no bypass entries; the
    /// always-on loopback exclusions are applied where the proxy is built.
    public static func parse(environmentValue raw: String) -> BrowserProxyConfiguration? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        switch trimmed.lowercased() {
        case "off", "none", "disable", "disabled", "direct":
            return .disabled
        default:
            break
        }

        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme,
              let host = components.host, !host.isEmpty,
              let port = components.port, (1...65535).contains(port) else {
            return nil
        }
        let type = BrowserProxyType(lenient: scheme)
        guard type != .off else { return nil }
        return BrowserProxyConfiguration(
            type: type,
            host: host,
            port: port,
            username: components.user ?? "",
            password: components.password ?? "",
            bypass: []
        )
    }

    // MARK: - Codable (lenient)

    private enum CodingKeys: String, CodingKey {
        case type, host, port, bypass
    }

    /// Decodes from `cmux.json`. `username`/`password` are intentionally NOT
    /// decoded — proxy credentials never come from the shared config file (see
    /// the type doc); they arrive only via the `CMUX_BROWSER_PROXY` override.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawType = (try? container.decode(String.self, forKey: .type)) ?? ""
        self.type = BrowserProxyType(lenient: rawType)
        self.host = (try? container.decode(String.self, forKey: .host)) ?? ""
        if let intPort = try? container.decode(Int.self, forKey: .port) {
            self.port = intPort
        } else if let stringPort = try? container.decode(String.self, forKey: .port),
                  let parsedPort = Int(stringPort.trimmingCharacters(in: .whitespacesAndNewlines)) {
            self.port = parsedPort
        } else {
            self.port = 0
        }
        self.username = ""
        self.password = ""
        self.bypass = (try? container.decode([String].self, forKey: .bypass)) ?? []
    }

    /// Encodes for `cmux.json`. `username`/`password` are intentionally omitted
    /// so a proxy credential can never be written into the shared config file.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type.rawValue, forKey: .type)
        try container.encode(host, forKey: .host)
        try container.encode(port, forKey: .port)
        try container.encode(bypass, forKey: .bypass)
    }

    // MARK: - SettingCodable

    public static func decodeFromUserDefaults(_ raw: Any?) -> BrowserProxyConfiguration? {
        guard let data = raw as? Data else { return nil }
        return try? JSONDecoder().decode(BrowserProxyConfiguration.self, from: data)
    }

    public func encodeForUserDefaults() -> Any {
        (try? JSONEncoder().encode(self)) ?? Data()
    }

    public static func decodeFromJSON(_ raw: Any?) -> BrowserProxyConfiguration? {
        guard let raw, !(raw is NSNull) else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: raw, options: .fragmentsAllowed) else {
            return nil
        }
        return try? JSONDecoder().decode(BrowserProxyConfiguration.self, from: data)
    }

    public func encodeForJSON() -> Any {
        guard let data = try? JSONEncoder().encode(self),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return NSNull()
        }
        return object
    }
}
