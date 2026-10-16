import Foundation

/// What moves a workspace to the top of its pin tier automatically.
///
/// Backs `app.reorderOnNotification`, which started as a Bool. The two legacy
/// modes keep that Bool representation in both UserDefaults and cmux.json
/// (`false` is ``off``, `true` is ``notifications``), so existing stored
/// values and config files keep their meaning and a downgrade reads them
/// unchanged. Only ``agentActivity`` is stored as a string.
public enum WorkspaceAutoReorderMode: String, CaseIterable, Sendable, SettingCodable {
    /// Never reorder automatically.
    case off
    /// Move a workspace when it receives a notification (the legacy `true`).
    case notifications
    /// Move a workspace on notifications and on meaningful agent lifecycle
    /// transitions (turn finished, needs input, error, new prompt), throttled
    /// and deferred while the user is looking at or pointing into the sidebar.
    case agentActivity

    /// Whether any automatic reordering is enabled.
    public var isEnabled: Bool { self != .off }

    public static func decodeFromUserDefaults(_ raw: Any?) -> Self? {
        if let legacy = Bool.decodeFromUserDefaults(raw) {
            return legacy ? .notifications : .off
        }
        return String.decodeFromUserDefaults(raw).flatMap(Self.init(rawValue:))
    }

    public func encodeForUserDefaults() -> Any { encodedValue }

    public static func decodeFromJSON(_ raw: Any?) -> Self? {
        if let legacy = Bool.decodeFromJSON(raw) {
            return legacy ? .notifications : .off
        }
        return String.decodeFromJSON(raw).flatMap(Self.init(rawValue:))
    }

    public func encodeForJSON() -> Any { encodedValue }

    private var encodedValue: Any {
        switch self {
        case .off: false
        case .notifications: true
        case .agentActivity: rawValue
        }
    }
}
