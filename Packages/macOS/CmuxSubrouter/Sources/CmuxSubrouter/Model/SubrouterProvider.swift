/// An AI-agent provider namespace known to the subrouter daemon.
///
/// Modeled as a raw-value struct (not an `enum`) so accounts from a newer
/// daemon with providers this build does not know about decode losslessly
/// instead of failing. The daemon currently reports ``codex`` and ``claude``;
/// Gemini profiles are listable via `sr gemini` only and never appear in the
/// daemon's HTTP responses.
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
}
