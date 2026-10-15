public import Foundation

/// One extension toolbar action of a Chromium tab, as the fork's
/// `cmux_ext_actions` reports it.
///
/// The toolbar draws pinned actions next to the address bar and the rest in
/// the Extensions menu.
public struct BrowserExtensionAction: Hashable, Sendable, Identifiable {
    /// The extension id.
    public var id: String
    /// The extension name.
    public var name: String
    /// The action title for this tab (tooltip).
    public var title: String
    /// The badge text for this tab, or "".
    public var badge: String
    /// The badge background as `#RRGGBBAA`, or "".
    public var badgeColor: String
    /// The badge text color as `#RRGGBBAA`, or "".
    public var badgeTextColor: String
    /// False when the action is disabled for this tab.
    public var isEnabled: Bool
    /// True when pinned to the toolbar.
    public var isPinned: Bool
    /// True when clicking opens a popup.
    public var hasPopup: Bool
    /// PNG bytes of the toolbar icon at 2x, with Chromium's badge and disabled state drawn in.
    public var iconPNG: Data?

    /// Creates an action snapshot.
    public init(
        id: String, name: String, title: String, badge: String = "", badgeColor: String = "",
        badgeTextColor: String = "", isEnabled: Bool = true, isPinned: Bool = false,
        hasPopup: Bool = false, iconPNG: Data? = nil
    ) {
        self.id = id
        self.name = name
        self.title = title
        self.badge = badge
        self.badgeColor = badgeColor
        self.badgeTextColor = badgeTextColor
        self.isEnabled = isEnabled
        self.isPinned = isPinned
        self.hasPopup = hasPopup
        self.iconPNG = iconPNG
    }

    /// Decodes the fork's JSON array.
    ///
    /// - Parameter json: The fork's JSON text.
    /// - Returns: The actions in Chromium's toolbar order, or an empty list for invalid input.
    public static func decodeList(_ json: String) -> [BrowserExtensionAction] {
        guard let data = json.data(using: .utf8),
              let items = try? JSONDecoder().decode([Wire].self, from: data) else {
            return []
        }
        return items.map { item in
            BrowserExtensionAction(
                id: item.id, name: item.name ?? item.id, title: item.title ?? item.name ?? "",
                badge: item.badge ?? "", badgeColor: item.badgeColor ?? "",
                badgeTextColor: item.badgeTextColor ?? "", isEnabled: item.enabled ?? true,
                isPinned: item.pinned ?? false, hasPopup: item.hasPopup ?? false,
                iconPNG: item.iconPNG.flatMap { Data(base64Encoded: $0) }
            )
        }
    }

    /// Parses `#RRGGBBAA` (or `#RRGGBB`) into sRGB components in `0...1`.
    ///
    /// - Parameter hex: The color text.
    /// - Returns: The components, or nil for malformed input.
    public static func rgba(_ hex: String) -> (red: Double, green: Double, blue: Double, alpha: Double)? {
        var text = hex
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6 || text.count == 8, let value = UInt32(text, radix: 16) else { return nil }
        let full = text.count == 6 ? (value << 8) | 0xFF : value
        return (
            Double((full >> 24) & 0xFF) / 255, Double((full >> 16) & 0xFF) / 255,
            Double((full >> 8) & 0xFF) / 255, Double(full & 0xFF) / 255
        )
    }

    private struct Wire: Decodable {
        var id: String
        var name: String?
        var title: String?
        var badge: String?
        var badgeColor: String?
        var badgeTextColor: String?
        var enabled: Bool?
        var pinned: Bool?
        var hasPopup: Bool?
        var iconPNG: String?

        enum CodingKeys: String, CodingKey {
            case id, name, title, badge, enabled, pinned
            case badgeColor = "badge_color"
            case badgeTextColor = "badge_text_color"
            case hasPopup = "has_popup"
            case iconPNG = "icon_png"
        }
    }
}
