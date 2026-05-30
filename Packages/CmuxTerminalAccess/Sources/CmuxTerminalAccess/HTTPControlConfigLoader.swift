import Foundation

/// Behavioral parser for the `httpControl` block in `cmux.json`
/// (D14 / E7).
///
/// **Locked symbol** — both Phase 1 Task 1.20 and Phase 2 Task 2.31
/// consume this exact entry point. The app-target config bootstrap
/// (Task 1.22) calls ``parse(_:)`` with the `httpControl` sub-object
/// bytes from `cmux.json` and maps the result onto a running
/// ``HTTPControlSettings`` instance.
///
/// The loader is intentionally a thin Codable round-trip so it can
/// be exercised from `swift test` against the package without
/// dragging in the app target or AppKit. Fields are optional so a
/// partial `httpControl` object (e.g. only `enabled`) is accepted;
/// invalid enum values (`transport = "bonkers"`) raise
/// ``DecodingError`` and bubble out to the caller.
///
/// ```swift
/// let json = #"{"enabled": true, "transport": "uds"}"#
/// let cfg = try HTTPControlConfigLoader.parse(Data(json.utf8))
/// assert(cfg.enabled == true)
/// assert(cfg.transport == .uds)
/// ```
public enum HTTPControlConfigLoader {
    /// Decode an `httpControl` block out of raw JSON bytes.
    ///
    /// - Parameter json: UTF-8 JSON bytes for the sub-object alone
    ///   (the caller is responsible for extracting it from the top
    ///   level `cmux.json` document).
    /// - Returns: A populated ``HTTPControlConfig``.
    /// - Throws: ``DecodingError`` for invalid types or unknown enum
    ///   values, or any error raised by `JSONDecoder`.
    public static func parse(_ json: Data) throws -> HTTPControlConfig {
        try JSONDecoder().decode(HTTPControlConfig.self, from: json)
    }
}

/// Decoded shape of a `cmux.json` `httpControl` block.
///
/// Every field is optional so a user can override only a subset of
/// the defaults defined in the JSON schema (`web/data/cmux.schema.json`).
/// The lifecycle wire-up (Task 1.22) applies each present field onto
/// the runtime ``HTTPControlSettings`` and leaves the rest at their
/// `UserDefaults`-backed values.
public struct HTTPControlConfig: Codable, Equatable, Sendable {
    /// Master switch for the HTTP control listener (UserDefaults
    /// key `httpControl.enabled`).
    public var enabled: Bool?
    /// Transport selection (`tcp` | `uds`).
    public var transport: HTTPControlTransport?
    /// TCP loopback port. Schema constrains to `[1024, 65535]`.
    public var tcpPort: Int?
    /// Filesystem path for the AF_UNIX socket.
    public var udsPath: String?
    /// Whether `type=raw` input payloads are accepted (spec §8.3).
    public var allowRawInput: Bool?
    /// Audit log file path (D4).
    public var auditLogPath: String?

    /// Memberwise initialiser. Synthesized one would be `internal`
    /// because the type is `public`; we provide an explicit `public`
    /// init so callers outside the module can construct test
    /// fixtures.
    public init(
        enabled: Bool? = nil,
        transport: HTTPControlTransport? = nil,
        tcpPort: Int? = nil,
        udsPath: String? = nil,
        allowRawInput: Bool? = nil,
        auditLogPath: String? = nil
    ) {
        self.enabled = enabled
        self.transport = transport
        self.tcpPort = tcpPort
        self.udsPath = udsPath
        self.allowRawInput = allowRawInput
        self.auditLogPath = auditLogPath
    }
}

/// Transport enum used by ``HTTPControlConfig``.
///
/// Mirrors the app-target ``HTTPControlSettings.Transport`` cases.
/// Lifecycle code translates between the two when applying a parsed
/// config to a running settings instance.
public enum HTTPControlTransport: String, Codable, Sendable {
    /// Loopback TCP listener.
    case tcp
    /// AF_UNIX listener at a user-configured path.
    case uds
}
