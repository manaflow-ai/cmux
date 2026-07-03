import Foundation

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
/// Only unauthenticated proxies are configurable: no proxy credential is read
/// from `cmux.json` (a shared, copyable config) or the process environment
/// (inherited by spawned terminals/agents), so a proxy password can't leak
/// through either channel. Authenticated proxies are a planned follow-up that
/// will source the credential from the secret store, the same boundary the
/// package keeps for `automation.socketPassword`.
public struct BrowserProxyConfiguration: Sendable, Equatable, Codable, SettingCodable {
    /// The proxy protocol, or ``BrowserProxyType/off`` to apply no proxy.
    public let type: BrowserProxyType
    /// Proxy server hostname or IP (e.g. `127.0.0.1`).
    public let host: String
    /// Proxy server TCP port (1...65535 when enabled).
    public let port: Int
    /// Hostname suffixes that connect directly instead of through the proxy.
    public let bypass: [String]

    /// The environment variable that overrides the cmux.json proxy.
    public static let environmentVariableName = "CMUX_BROWSER_PROXY"

    /// The "no proxy" configuration, also the default when the key is absent.
    public static let disabled = BrowserProxyConfiguration(
        type: .off, host: "", port: 0, bypass: []
    )

    /// Memberwise initializer.
    public init(
        type: BrowserProxyType,
        host: String,
        port: Int,
        bypass: [String]
    ) {
        self.type = type
        self.host = host
        self.port = port
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

    /// Parses a `CMUX_BROWSER_PROXY` value of the form `scheme://host:port`
    /// (e.g. `socks5://127.0.0.1:1080`), or a bare disable keyword (`off`,
    /// `none`, `disabled`, `direct`).
    ///
    /// Returns `nil` when the value is neither — callers then fall back to the
    /// cmux.json configuration. Any `user:pass@` userinfo is ignored:
    /// authenticated proxies are not supported, and the credential is
    /// deliberately not extracted so it never reaches a `ProxyConfiguration`
    /// through this insecure channel.
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
            bypass: []
        )
    }

    // MARK: - Codable (lenient)

    private enum CodingKeys: String, CodingKey {
        case type, host, port, bypass
    }

    /// Creates a proxy configuration from the `browser.proxy` JSON payload.
    ///
    /// Decoding is intentionally lenient: missing or malformed fields fall back
    /// to safe disabled values so the wider settings file can still load.
    ///
    /// - Parameter decoder: The decoder supplying the proxy object.
    /// - Throws: Any keyed-container access error emitted by the decoder.
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
        self.bypass = (try? container.decode([String].self, forKey: .bypass)) ?? []
    }

    /// Encodes the proxy configuration using the stable settings key names.
    ///
    /// - Parameter encoder: The encoder receiving the proxy object.
    /// - Throws: Any encoding error emitted by the encoder.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type.rawValue, forKey: .type)
        try container.encode(host, forKey: .host)
        try container.encode(port, forKey: .port)
        try container.encode(bypass, forKey: .bypass)
    }

    // MARK: - SettingCodable

    /// Decodes a configuration stored in `UserDefaults`.
    ///
    /// - Parameter raw: The stored defaults value, expected to be encoded
    ///   `Data`.
    /// - Returns: The decoded configuration, or `nil` when the stored value has
    ///   the wrong shape.
    public static func decodeFromUserDefaults(_ raw: Any?) -> BrowserProxyConfiguration? {
        guard let data = raw as? Data else { return nil }
        return try? JSONDecoder().decode(BrowserProxyConfiguration.self, from: data)
    }

    /// Encodes this configuration into the `UserDefaults` representation.
    ///
    /// - Returns: JSON-encoded `Data` suitable for storage by
    ///   ``SettingCodable``.
    public func encodeForUserDefaults() -> Any {
        (try? JSONEncoder().encode(self)) ?? Data()
    }

    /// Decodes a configuration from the JSON object used by `cmux.json`.
    ///
    /// - Parameter raw: The JSON object for `browser.proxy`.
    /// - Returns: The decoded configuration, or `nil` for absent, null, or
    ///   non-object values.
    public static func decodeFromJSON(_ raw: Any?) -> BrowserProxyConfiguration? {
        guard let raw, !(raw is NSNull) else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: raw, options: .fragmentsAllowed) else {
            return nil
        }
        return try? JSONDecoder().decode(BrowserProxyConfiguration.self, from: data)
    }

    /// Encodes this configuration into a JSON object for `cmux.json`.
    ///
    /// - Returns: A Foundation JSON object, or `NSNull` if encoding fails.
    public func encodeForJSON() -> Any {
        guard let data = try? JSONEncoder().encode(self),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return NSNull()
        }
        return object
    }
}
