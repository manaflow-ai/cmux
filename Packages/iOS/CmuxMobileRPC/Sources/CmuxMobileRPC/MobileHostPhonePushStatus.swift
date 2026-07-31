import Foundation

/// The authenticated Mac-side gate for forwarding notifications to this phone.
///
/// The Mac includes this only after the caller proves same-account ownership.
/// Missing or unknown values must therefore be treated as unavailable, never as
/// ready.
public struct MobileHostPhonePushStatus: Decodable, Equatable, Sendable {
    /// When the Mac forwards otherwise-qualifying notifications.
    public enum Mode: String, Decodable, Equatable, Sendable {
        /// Forward only while the Mac is locked, asleep, or idle.
        case onlyWhenAway
        /// Forward regardless of Mac presence.
        case always
    }

    /// What the authenticated status exchange proves about account ownership.
    public enum AccountScope: String, Decodable, Equatable, Sendable {
        /// The Mac verified the phone's Stack token against its own account.
        case verifiedSameAccount = "verified_same_account"
    }

    /// The Mac's sanitized current decision for a would-be notification.
    public enum Admission: String, Decodable, Equatable, Sendable {
        case allowed
        case forwardingDisabled = "forwarding_disabled"
        case suppressedMacActive = "suppressed_mac_active"
        case unknown
    }

    /// Whether the Mac's independent forwarding privacy gate is enabled.
    public let forwardingEnabled: Bool
    /// The Mac's live forwarding mode.
    public let mode: Mode
    /// Whether the current mode and presence admit a forward right now.
    public let admission: Admission
    /// Whether terminal title/body content is redacted before upload.
    public let hideContent: Bool
    /// The API base URL the Mac will send the notification through.
    public let apiOrigin: String
    /// The account relationship proven by the authenticated RPC.
    public let accountScope: AccountScope

    /// Creates an authenticated Mac push-status value.
    public init(
        forwardingEnabled: Bool,
        mode: Mode,
        admission: Admission = .unknown,
        hideContent: Bool = false,
        apiOrigin: String,
        accountScope: AccountScope
    ) {
        self.forwardingEnabled = forwardingEnabled
        self.mode = mode
        self.admission = admission
        self.hideContent = hideContent
        self.apiOrigin = apiOrigin
        self.accountScope = accountScope
    }

    private enum CodingKeys: String, CodingKey {
        case forwardingEnabled = "forwarding_enabled"
        case mode
        case admission
        case hideContent = "hide_content"
        case apiOrigin = "api_origin"
        case accountScope = "account_scope"
    }
}
