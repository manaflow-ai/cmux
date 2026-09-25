/// The per-notification `effects` override a create request may carry, in the
/// same shape a notification hook emits (`{"desktop": false}`). Every field is
/// optional; an absent field keeps the policy default, and hooks still run
/// afterwards and may override what the caller asked for.
public struct ControlNotificationEffectsPatch: Codable, Sendable, Equatable {
    public var record: Bool?
    public var markUnread: Bool?
    public var reorderWorkspace: Bool?
    public var desktop: Bool?
    public var sound: Bool?
    public var command: Bool?
    public var paneFlash: Bool?

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
