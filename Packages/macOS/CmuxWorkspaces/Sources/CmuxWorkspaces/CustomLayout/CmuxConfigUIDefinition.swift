import Foundation

/// The `cmux.json` top-level `ui` block wire-schema: the customizable tab-bar
/// chrome a user declares in config (currently the new-workspace plus button
/// and the surface tab-bar button row).
///
/// Decoded as part of the `CmuxConfigFile.ui` field; pure value type with no
/// AppKit/rendering coupling. The AppKit `CmuxButtonIcon` image renderer that
/// turns a decoded icon into an `NSImage` stays app-side.
public struct CmuxConfigUIDefinition: Codable, Sendable, Hashable {
    /// Placement override for the new-workspace plus button (action, icon,
    /// tooltip, and right-click context menu).
    public var newWorkspace: CmuxConfigButtonPlacement?
    /// The surface tab-bar button row override.
    public var surfaceTabBar: CmuxSurfaceTabBarUIDefinition?

    public init(
        newWorkspace: CmuxConfigButtonPlacement? = nil,
        surfaceTabBar: CmuxSurfaceTabBarUIDefinition? = nil
    ) {
        self.newWorkspace = newWorkspace
        self.surfaceTabBar = surfaceTabBar
    }
}

/// The `cmux.json` `ui.surfaceTabBar` wire-schema: the user-declared surface
/// tab-bar button row.
public struct CmuxSurfaceTabBarUIDefinition: Codable, Sendable, Hashable {
    /// The ordered surface tab-bar buttons; `nil` means "use the built-in
    /// defaults" (distinct from an empty array, which hides all buttons).
    public var buttons: [CmuxSurfaceTabBarButton]?

    public init(buttons: [CmuxSurfaceTabBarButton]? = nil) {
        self.buttons = buttons
    }
}

/// The `cmux.json` placement wire-schema for a single configurable button (the
/// new-workspace plus button): an action id plus optional icon, tooltip, and a
/// right-click context menu.
///
/// The custom `Decodable` accepts `rightClick` as an alias for `contextMenu`
/// and trims surrounding whitespace from `action`/`tooltip` (a blank `tooltip`
/// decodes to `nil`; a blank `action` is a decoding error).
public struct CmuxConfigButtonPlacement: Codable, Sendable, Hashable {
    /// The button action id (trimmed; blank is a decoding error).
    public var action: String?
    /// The button icon.
    public var icon: CmuxButtonIcon?
    /// The button tooltip (trimmed; blank decodes to `nil`).
    public var tooltip: String?
    /// The right-click context-menu rows (decoded from `contextMenu` or its
    /// `rightClick` alias).
    public var contextMenu: [CmuxConfigContextMenuItem]?

    private enum CodingKeys: String, CodingKey {
        case action
        case icon
        case tooltip
        case contextMenu
        case rightClick
    }

    public init(
        action: String? = nil,
        icon: CmuxButtonIcon? = nil,
        tooltip: String? = nil,
        contextMenu: [CmuxConfigContextMenuItem]? = nil
    ) {
        self.action = action
        self.icon = icon
        self.tooltip = tooltip
        self.contextMenu = contextMenu
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        action = try Self.trimmedString(forKey: .action, in: container)
        icon = try container.decodeIfPresent(CmuxButtonIcon.self, forKey: .icon)
        tooltip = try Self.trimmedString(forKey: .tooltip, in: container, allowBlankAsNil: true)
        contextMenu = try container.decodeIfPresent([CmuxConfigContextMenuItem].self, forKey: .contextMenu)
            ?? container.decodeIfPresent([CmuxConfigContextMenuItem].self, forKey: .rightClick)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(action, forKey: .action)
        try container.encodeIfPresent(icon, forKey: .icon)
        try container.encodeIfPresent(tooltip, forKey: .tooltip)
        try container.encodeIfPresent(contextMenu, forKey: .contextMenu)
    }

    private static func trimmedString(
        forKey key: CodingKeys,
        in container: KeyedDecodingContainer<CodingKeys>,
        allowBlankAsNil: Bool = false
    ) throws -> String? {
        guard container.contains(key) else { return nil }
        let raw = try container.decode(String.self, forKey: key)
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            if allowBlankAsNil { return nil }
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: container,
                debugDescription: "\(key.stringValue) must not be blank"
            )
        }
        return trimmed
    }
}
