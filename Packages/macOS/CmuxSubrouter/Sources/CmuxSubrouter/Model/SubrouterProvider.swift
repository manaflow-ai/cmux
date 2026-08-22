/// An AI-agent provider namespace known to the subrouter daemon.
///
/// Modeled as a raw-value struct (not an `enum`) so provider values added by a
/// newer daemon decode losslessly instead of failing the whole response. The
/// transport can therefore carry providers that do not yet have a first-class
/// cmux account-management surface.
public struct SubrouterProvider: RawRepresentable, Hashable, Sendable, Codable {
    /// The OpenAI Codex provider (`"codex"`). Switching a Codex account also
    /// syncs OpenCode and pi credential files on the daemon side.
    public static let codex = SubrouterProvider(rawValue: "codex")
    /// The Anthropic Claude provider (`"claude"`). Accounts are named
    /// profiles; the profile name doubles as the account id.
    public static let claude = SubrouterProvider(rawValue: "claude")

    /// The wire string exactly as the daemon reported it.
    public let rawValue: String

    /// Creates a provider from its wire string.
    /// - Parameter rawValue: The provider string (e.g. `"codex"`).
    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(from decoder: any Decoder) throws {
        self.rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// Whether cmux can drive an account switch for this provider through the
    /// `sr` CLI (`sr switch` for Codex, `sr claude switch` for Claude).
    public var supportsSwitching: Bool {
        self == .codex || self == .claude
    }

    /// Whether cmux has a first-class account-management surface for this
    /// provider. Unknown daemon providers remain available in the raw
    /// snapshot for diagnostics, but are not presented as incomplete account
    /// sections in the panel or footer switcher.
    ///
    /// The current account-management actions and switching path cover the
    /// same provider set, so this capability intentionally follows
    /// ``supportsSwitching`` as the shared policy source.
    public var supportsAccountManagement: Bool {
        supportsSwitching
    }
}
