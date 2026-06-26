/// Contextual signals carried alongside a notification through the policy hook
/// pipeline: the originating working directory and config path, the id of the
/// hook currently running, and whether the app and the owning panel are
/// focused. Encoded to a hook's stdin and patched back from its stdout.
public struct TerminalNotificationPolicyContext: Codable, Sendable, Equatable {
    /// The working directory associated with the notification, if any.
    public var cwd: String?
    /// The config file path the active hook was resolved from, if any.
    public var configPath: String?
    /// The id of the hook currently being evaluated, if any.
    public var hookId: String?
    /// Whether the application is focused.
    public var appFocused: Bool
    /// Whether the panel that owns the notification is focused.
    public var focusedPanel: Bool

    /// Creates a notification-policy context.
    public init(
        cwd: String?,
        configPath: String?,
        hookId: String?,
        appFocused: Bool,
        focusedPanel: Bool
    ) {
        self.cwd = cwd
        self.configPath = configPath
        self.hookId = hookId
        self.appFocused = appFocused
        self.focusedPanel = focusedPanel
    }
}

/// Partial, hook-supplied overrides for ``TerminalNotificationPolicyContext``.
/// String fields are doubly optional so a hook can explicitly null them out,
/// while the booleans are single-optional (present or absent).
struct TerminalNotificationPolicyContextPatch: Decodable {
    var cwd: String??
    var configPath: String??
    var hookId: String??
    var appFocused: Bool?
    var focusedPanel: Bool?

    private enum CodingKeys: String, CodingKey {
        case cwd
        case configPath
        case hookId
        case appFocused
        case focusedPanel
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cwd = try container.decodeNullableValueIfPresent(String.self, forKey: .cwd)
        configPath = try container.decodeNullableValueIfPresent(String.self, forKey: .configPath)
        hookId = try container.decodeNullableValueIfPresent(String.self, forKey: .hookId)
        appFocused = try container.decodeIfNonNullValuePresent(Bool.self, forKey: .appFocused)
        focusedPanel = try container.decodeIfNonNullValuePresent(Bool.self, forKey: .focusedPanel)
    }

    func merged(into context: TerminalNotificationPolicyContext) -> TerminalNotificationPolicyContext {
        var merged = context
        if let cwd {
            merged.cwd = cwd
        }
        if let configPath {
            merged.configPath = configPath
        }
        if let hookId {
            merged.hookId = hookId
        }
        if let appFocused {
            merged.appFocused = appFocused
        }
        if let focusedPanel {
            merged.focusedPanel = focusedPanel
        }
        return merged
    }
}
