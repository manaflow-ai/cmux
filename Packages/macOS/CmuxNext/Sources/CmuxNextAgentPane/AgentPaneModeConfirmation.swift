/// The setting a frame asks for, as the Rust policy's facts name it (R2, P2). Permission modes and
/// the Fast mode toggle are direct menu choices: the user's gesture is the consent. Other config
/// options that are not free may still use a native sheet.
public nonisolated enum AgentPaneModeConfirmation: Equatable, Sendable, CustomStringConvertible {
    /// session/set_mode, or set_config_option of the `mode` option, to this mode id.
    case mode(String)
    /// set_config_option of another option that is not free, to this value (as text).
    case option(id: String, value: String)

    /// Whether the user confirms it on the native sheet. Permission modes and Fast mode never do.
    public var needsSheet: Bool {
        switch self {
        case .mode: return false
        case .option(let id, _):
            let normalized = id.replacingOccurrences(of: "_", with: "-").lowercased()
            return !["fast", "fast-mode"].contains(normalized)
        }
    }

    /// The markers and allowed modes of cmux-tui/spec/full-access-modes.json, which acpmux applies too
    /// (FullAccessModeRuleTests keeps the two the same).
    static let fullAccessMarkers = ["bypass", "fullaccess", "yolo", "dangerous", "autoapprove", "skippermissions"]
    static let allowedModes = ["default", "acceptEdits", "plan", "dontAsk", "auto", "ask", "read-only", "agent", "full-auto",
                               "autoEdit"]

    /// An option value that skips approvals (bypass permissions, full access, yolo), by the rule
    /// acpmux enforces: lowercased, without `-`, `_` or spaces, it contains a marker.
    public static func isFullAccess(_ value: String) -> Bool {
        let folded = fold(value)
        return fullAccessMarkers.contains { folded.contains($0) }
    }

    /// A permission mode that skips approvals, by the allowlist acpmux enforces: only a mode whose folded
    /// id is one of `allowedModes` (and holds no marker) asks, so a mode no one reviewed counts as full access.
    public static func isFullAccessMode(_ mode: String) -> Bool {
        isFullAccess(mode) || !allowedModes.map(fold).contains(fold(mode))
    }

    private static func fold(_ id: String) -> String {
        String(id.lowercased().filter { !"-_ ".contains($0) })
    }

    /// Whether this switch puts the session in full access: a mode by the allowlist, another
    /// option's value by its markers.
    public var skipsApprovals: Bool {
        switch self {
        case .mode(let mode): Self.isFullAccessMode(mode)
        case .option(_, let value): Self.isFullAccess(value)
        }
    }

    /// For logs and tests: the mode, or `id = value`.
    public var description: String {
        switch self {
        case .mode(let mode): mode
        case .option(let id, let value): "\(id) = \(value)"
        }
    }
}
