/// The per-notification `effects` override a create request may carry, in the
/// same shape a notification hook emits (`{"desktop": false}`). Every field is
/// optional; an absent field keeps the policy default, and hooks still run
/// afterwards and may override what the caller asked for.
public struct ControlNotificationEffectsPatch: Codable, Sendable, Equatable {
    /// Whether the notification is kept in history and the Notifications panel.
    public var record: Bool?
    /// Whether the notification marks its workspace and surface unread.
    public var markUnread: Bool?
    /// Whether the notification moves its workspace up in the sidebar.
    public var reorderWorkspace: Bool?
    /// Whether the notification posts a native macOS banner.
    public var desktop: Bool?
    /// Whether the notification plays its sound.
    public var sound: Bool?
    /// Whether the notification runs the user's `notifications.command`.
    public var command: Bool?
    /// Whether the notification flashes its pane ring.
    public var paneFlash: Bool?

    /// Creates a patch from the given field overrides; every field defaults to absent.
    public init(
        record: Bool? = nil,
        markUnread: Bool? = nil,
        reorderWorkspace: Bool? = nil,
        desktop: Bool? = nil,
        sound: Bool? = nil,
        command: Bool? = nil,
        paneFlash: Bool? = nil
    ) {
        self.record = record
        self.markUnread = markUnread
        self.reorderWorkspace = reorderWorkspace
        self.desktop = desktop
        self.sound = sound
        self.command = command
        self.paneFlash = paneFlash
    }

    /// Decodes the wire object strictly: an object whose keys are all known
    /// effects and whose values are all JSON booleans. Numbers, strings and
    /// unknown keys are rejected rather than coerced, so `{"desktop": 2}` is
    /// invalid instead of silently true.
    public init?(json: JSONValue) {
        guard case .object(let fields) = json else { return nil }
        var patch = Self()
        for (key, value) in fields {
            guard case .bool(let flag) = value else { return nil }
            switch key {
            case "record": patch.record = flag
            case "markUnread": patch.markUnread = flag
            case "reorderWorkspace": patch.reorderWorkspace = flag
            case "desktop": patch.desktop = flag
            case "sound": patch.sound = flag
            case "command": patch.command = flag
            case "paneFlash": patch.paneFlash = flag
            default: return nil
            }
        }
        self = patch
    }
}
