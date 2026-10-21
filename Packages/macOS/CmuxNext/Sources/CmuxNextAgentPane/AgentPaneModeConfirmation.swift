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

    /// The markers of cmux-tui/spec/full-access-modes.json, which acpmux applies too
    /// (FullAccessModeRuleTests keeps the two the same).
    static let fullAccessMarkers = ["bypass", "fullaccess", "yolo", "dangerous", "autoapprove", "skippermissions"]

    /// A mode or option value that skips approvals (bypass permissions, full access, yolo), by the
    /// rule acpmux enforces: lowercased, without `-`, `_` or spaces, it contains a marker.
    public static func isFullAccess(_ mode: String) -> Bool {
        let folded = String(mode.lowercased().filter { !"-_ ".contains($0) })
        return fullAccessMarkers.contains { folded.contains($0) }
    }

    /// For logs and tests: the mode, or `id = value`.
    public var description: String {
        switch self {
        case .mode(let mode): mode
        case .option(let id, let value): "\(id) = \(value)"
        }
    }
}
