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
    /// The Mac's stable pairing device id. The minimal v3 pairing QR no
    /// longer carries it, so this is where a freshly paired phone learns
    /// which paired-Mac record the connection belongs to (reconnect-on-launch
    /// and the host switcher key on it). `nil` from older Macs.
    public let macDeviceID: String?
    /// The Mac app's marketing version, for warning-only compatibility checks.
    public let macAppVersion: String?
    /// The Mac app's build number, for warning display.
    public let macAppBuild: String?

    private enum CodingKeys: String, CodingKey {
        case capabilities
        case terminalFidelity = "terminal_fidelity"
        case macDisplayName = "mac_display_name"
        case macDeviceID = "mac_device_id"
        case macAppVersion = "mac_app_version"
        case macAppBuild = "mac_app_build"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        capabilities = (try container.decodeIfPresent([String].self, forKey: .capabilities)) ?? []
        terminalFidelity = try container.decodeIfPresent(String.self, forKey: .terminalFidelity)
        macDisplayName = try container.decodeIfPresent(String.self, forKey: .macDisplayName)
        macDeviceID = try container.decodeIfPresent(String.self, forKey: .macDeviceID)
        macAppVersion = try container.decodeIfPresent(String.self, forKey: .macAppVersion)
        macAppBuild = try container.decodeIfPresent(String.self, forKey: .macAppBuild)
    }

    /// Decode a host-status response from raw JSON data.
    /// - Parameter data: The RPC result payload.
    /// - Returns: The decoded response.
    /// - Throws: A decoding error if the payload is not a JSON object.
    public static func decode(_ data: Data) throws -> MobileHostStatusResponse {
        try JSONDecoder().decode(Self.self, from: data)
    }
}
