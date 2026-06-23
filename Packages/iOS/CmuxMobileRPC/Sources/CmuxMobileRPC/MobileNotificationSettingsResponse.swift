public import Foundation
public import CmuxMobileShellModel

/// Typed decoder for the Mac's `notification.settings.get` and
/// `notification.settings.set` RPC result.
public struct MobileNotificationSettingsResponse: Decodable, Sendable {
    /// The Mac-side forwarding master toggle.
    public let isEnabled: Bool
    /// The Mac-side forwarding mode.
    public let forwardingMode: MobileNotificationForwardingMode
    /// Whether the Mac hides terminal content in forwarded notifications.
    public let hidesContent: Bool

    private enum CodingKeys: String, CodingKey {
        case isEnabled = "enabled"
        case forwardingMode = "mode"
        case hidesContent = "hide_content"
    }

    /// Decodes a settings response, using the phone-active defaults when an
    /// older Mac omits fields.
    /// - Parameter decoder: The JSON decoder for the result payload.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        let rawMode = try container.decodeIfPresent(String.self, forKey: .forwardingMode)
        forwardingMode = rawMode.flatMap(MobileNotificationForwardingMode.init(rawValue:))
            ?? MobileNotificationForwardingMode.defaultMode
        hidesContent = try container.decodeIfPresent(Bool.self, forKey: .hidesContent) ?? false
    }
}
