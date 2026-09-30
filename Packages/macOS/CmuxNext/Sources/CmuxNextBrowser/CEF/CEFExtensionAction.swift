import AppKit
public import Foundation

/// One extension toolbar action, as `cmux_ext_actions` reports it.
public nonisolated struct CEFExtensionAction: Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var title: String
    public var badge: String
    /// `#RRGGBBAA`.
    public var badgeColor: String
    public var badgeTextColor: String
    public var isEnabled: Bool
    public var isPinned: Bool
    public var hasPopup: Bool
    /// PNG bytes at 2x of the toolbar button: the icon centered with
    /// Chromium's badge and disabled state, as Chrome's toolbar draws it.
    public var iconPNG: Data?

    /// The icon size to request: the toolbar button at 2x.
    @MainActor static var iconPixels: Int32 { Int32((OmnibarStyle.buttonSize * 2).rounded()) }

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

    /// Decodes the fork's JSON array. Invalid input yields an empty list.
    public static func decodeList(_ json: String) -> [CEFExtensionAction] {
        guard let data = json.data(using: .utf8),
              let items = try? JSONDecoder().decode([Wire].self, from: data) else {
            return []
        }
        return items.map { item in
            CEFExtensionAction(
                id: item.id, name: item.name ?? item.id, title: item.title ?? item.name ?? "",
                badge: item.badge ?? "", badgeColor: item.badge_color ?? "",
                badgeTextColor: item.badge_text_color ?? "", isEnabled: item.enabled ?? true,
                isPinned: item.pinned ?? false, hasPopup: item.has_popup ?? false,
                iconPNG: item.icon_png.flatMap { Data(base64Encoded: $0) }
            )
        }
    }

    /// Parses `#RRGGBBAA` (or `#RRGGBB`) into sRGB components in 0...1.
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
        var badge_color: String?
        var badge_text_color: String?
        var enabled: Bool?
        var pinned: Bool?
        var has_popup: Bool?
        var icon_png: String?
    }
}
