/// The set of side effects a notification may produce, each defaulting to
/// enabled. A policy hook can disable any of them by patching the matching key;
/// a key omitted from the hook output decodes back to enabled.
public struct TerminalNotificationPolicyEffects: Codable, Sendable, Equatable {
    /// Whether the notification is recorded in the store.
    public var record: Bool = true
    /// Whether the owning workspace is marked unread.
    public var markUnread: Bool = true
    /// Whether the owning workspace is reordered to surface the notification.
    public var reorderWorkspace: Bool = true
    /// Whether a desktop notification is delivered.
    public var desktop: Bool = true
    /// Whether a sound is played.
    public var sound: Bool = true
    /// Whether the configured notification command is run.
    public var command: Bool = true
    /// Whether the owning pane flashes.
    public var paneFlash: Bool = true

    private enum CodingKeys: String, CodingKey {
        case record
        case markUnread
        case reorderWorkspace
        case desktop
        case sound
        case command
        case paneFlash
    }

    /// Creates an effects value with every effect enabled.
    public init() {}

    /// Decodes effects, treating any omitted key as enabled.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        record = try container.decodeIfPresent(Bool.self, forKey: .record) ?? true
        markUnread = try container.decodeIfPresent(Bool.self, forKey: .markUnread) ?? true
        reorderWorkspace = try container.decodeIfPresent(Bool.self, forKey: .reorderWorkspace) ?? true
        desktop = try container.decodeIfPresent(Bool.self, forKey: .desktop) ?? true
        sound = try container.decodeIfPresent(Bool.self, forKey: .sound) ?? true
        command = try container.decodeIfPresent(Bool.self, forKey: .command) ?? true
        paneFlash = try container.decodeIfPresent(Bool.self, forKey: .paneFlash) ?? true
    }
}

/// Partial, hook-supplied overrides for ``TerminalNotificationPolicyEffects``.
/// Each field is optional so a hook may toggle only the effects it cares about.
struct TerminalNotificationPolicyEffectsPatch: Decodable {
    var record: Bool?
    var markUnread: Bool?
    var reorderWorkspace: Bool?
    var desktop: Bool?
    var sound: Bool?
    var command: Bool?
    var paneFlash: Bool?

    func merged(into effects: TerminalNotificationPolicyEffects) -> TerminalNotificationPolicyEffects {
        var merged = effects
        if let record {
            merged.record = record
        }
        if let markUnread {
            merged.markUnread = markUnread
        }
        if let reorderWorkspace {
            merged.reorderWorkspace = reorderWorkspace
        }
        if let desktop {
            merged.desktop = desktop
        }
        if let sound {
            merged.sound = sound
        }
        if let command {
            merged.command = command
        }
        if let paneFlash {
            merged.paneFlash = paneFlash
        }
        return merged
    }
}
