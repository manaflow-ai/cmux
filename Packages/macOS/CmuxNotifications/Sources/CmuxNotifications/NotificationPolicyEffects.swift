/// The delivery effects a terminal notification triggers: history and the
/// Notifications panel, unread state, the sidebar reorder, the native banner,
/// the sound, the user's `notifications.command`, and the pane flash. Every
/// effect defaults on; a hook or a caller turns individual effects off.
public struct NotificationPolicyEffects: Codable, Sendable, Equatable {
    /// Keep the notification in history and the Notifications panel.
    public var record: Bool
    /// Mark the workspace and surface unread.
    public var markUnread: Bool
    /// Move the workspace up in the sidebar.
    public var reorderWorkspace: Bool
    /// Post a native macOS banner.
    public var desktop: Bool
    /// Play the notification sound.
    public var sound: Bool
    /// Run the user's `notifications.command`.
    public var command: Bool
    /// Flash the pane ring.
    public var paneFlash: Bool

    private enum CodingKeys: String, CodingKey {
        case record
        case markUnread
        case reorderWorkspace
        case desktop
        case sound
        case command
        case paneFlash
    }

    /// Creates the effects; every parameter defaults on, so `NotificationPolicyEffects()` is the policy default.
    public init(
        record: Bool = true,
        markUnread: Bool = true,
        reorderWorkspace: Bool = true,
        desktop: Bool = true,
        sound: Bool = true,
        command: Bool = true,
        paneFlash: Bool = true
    ) {
        self.record = record
        self.markUnread = markUnread
        self.reorderWorkspace = reorderWorkspace
        self.desktop = desktop
        self.sound = sound
        self.command = command
        self.paneFlash = paneFlash
    }

    /// The defaults with a caller's override merged in; `nil` is the plain defaults.
    public init(applying patch: NotificationPolicyEffectsPatch?) {
        self = patch?.merged(into: Self()) ?? Self()
    }

    /// Every delivery effect disabled. Workspace mute is an admission gate;
    /// keeping this constructor exhaustive prevents a newly added effect from
    /// accidentally leaking through a muted workspace.
    public static var allSuppressed: Self {
        Self(
            record: false,
            markUnread: false,
            reorderWorkspace: false,
            desktop: false,
            sound: false,
            command: false,
            paneFlash: false
        )
    }

    /// Decodes a hook's `effects` object; an absent key keeps that effect on.
    public init(from decoder: any Decoder) throws {
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

/// A partial effects override: what a hook emits under `effects`, and what a
/// `cmux notify --desktop false` request carries in before hooks run. Every
/// field is optional; an absent field leaves that effect as it was.
public struct NotificationPolicyEffectsPatch: Codable, Sendable, Equatable {
    /// Overrides `record`, the history and Notifications panel entry.
    public var record: Bool?
    /// Overrides `markUnread`, the workspace and surface unread state.
    public var markUnread: Bool?
    /// Overrides `reorderWorkspace`, the sidebar reorder.
    public var reorderWorkspace: Bool?
    /// Overrides `desktop`, the native macOS banner.
    public var desktop: Bool?
    /// Overrides `sound`.
    public var sound: Bool?
    /// Overrides `command`, the user's `notifications.command`.
    public var command: Bool?
    /// Overrides `paneFlash`, the pane ring.
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

    /// Returns `effects` with every present field of this patch applied.
    public func merged(into effects: NotificationPolicyEffects) -> NotificationPolicyEffects {
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
