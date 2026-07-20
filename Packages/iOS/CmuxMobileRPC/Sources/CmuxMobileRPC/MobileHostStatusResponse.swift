public import CMUXMobileCore
public import Foundation

/// Typed decoder for the `mobile.host.status` RPC result.
///
/// Drives terminal-output transport negotiation: the iOS client prefers the
/// render-grid transport when the Mac either advertises the render-grid
/// capability or reports `terminal_fidelity == "render_grid"`, and otherwise
/// falls back to raw bytes.
public struct MobileHostStatusResponse: Decodable, Sendable {
    /// Capability identifiers the host advertises (for example
    /// `terminal.render_grid.v1`).
    public let capabilities: [String]
    /// The host's reported terminal fidelity (for example `render_grid`), if any.
    public let terminalFidelity: String?
    /// The Mac's user-facing name. The pairing QR no longer carries the name,
    /// so this is where a freshly paired phone learns what to call the Mac.
    /// `nil` from older Macs that predate the field.
    public let macDisplayName: String?
    /// The Mac's stable pairing device id. The minimal v2 pairing QR no
    /// longer carries it, so this is where a freshly paired phone learns
    /// which paired-Mac record the connection belongs to (reconnect-on-launch
    /// and the host switcher key on it). `nil` from older Macs.
    public let macDeviceID: String?
    /// The Mac app instance's authoritative route tag. `nil` from older Macs
    /// that predate per-instance route authority.
    public let macInstanceTag: String?
    /// Process-unique epoch for the Mac's terminal-theme revision counter.
    /// A changed value tells iOS that low revisions belong to a new producer.
    public let terminalThemeRevisionEpoch: String?
    /// The Mac app's marketing version, for warning-only compatibility checks.
    public let macAppVersion: String?
    /// The Mac app's build number, for warning display.
    public let macAppBuild: String?
    /// The Mac's resolved terminal theme (effective colors after applying any
    /// named ghostty theme, cmux's managed defaults, and explicit overrides).
    /// The phone applies this so its embedded terminal matches the Mac's
    /// colors. `nil` from older Macs that predate the field, in which case the
    /// phone keeps its built-in Monokai default.
    public let theme: TerminalTheme?

    private enum CodingKeys: String, CodingKey {
        case capabilities
        case terminalFidelity = "terminal_fidelity"
        case macDisplayName = "mac_display_name"
        case macDeviceID = "mac_device_id"
        case macInstanceTag = "mac_instance_tag"
        case terminalThemeRevisionEpoch = "terminal_theme_revision_epoch"
        case macAppVersion = "mac_app_version"
        case macAppBuild = "mac_app_build"
        case theme
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        capabilities = (try container.decodeIfPresent([String].self, forKey: .capabilities)) ?? []
        terminalFidelity = try container.decodeIfPresent(String.self, forKey: .terminalFidelity)
        macDisplayName = try container.decodeIfPresent(String.self, forKey: .macDisplayName)
        macDeviceID = try container.decodeIfPresent(String.self, forKey: .macDeviceID)
            .map(cmxCanonicalDeviceID)
        macInstanceTag = try container.decodeIfPresent(String.self, forKey: .macInstanceTag)
        terminalThemeRevisionEpoch = try container.decodeIfPresent(String.self, forKey: .terminalThemeRevisionEpoch)
        macAppVersion = try container.decodeIfPresent(String.self, forKey: .macAppVersion)
        macAppBuild = try container.decodeIfPresent(String.self, forKey: .macAppBuild)
        // A present-but-malformed `theme` must not fail the whole status decode.
        // The status payload also drives transport negotiation and Mac-identity
        // adoption; a decode throw here would force raw-bytes transport and skip
        // capability/identity follow-ups over a purely cosmetic field. Decode it
        // leniently: a bad theme object yields `nil` and the phone keeps its
        // built-in Monokai default, exactly like an older Mac that omits it.
        theme = (try? container.decodeIfPresent(TerminalTheme.self, forKey: .theme)) ?? nil
    }

    /// Decode a host-status response from raw JSON data.
    /// - Parameter data: The RPC result payload.
    /// - Returns: The decoded response.
    /// - Throws: A decoding error if the payload is not a JSON object.
    public static func decode(_ data: Data) throws -> MobileHostStatusResponse {
        try JSONDecoder().decode(Self.self, from: data)
    }
}
