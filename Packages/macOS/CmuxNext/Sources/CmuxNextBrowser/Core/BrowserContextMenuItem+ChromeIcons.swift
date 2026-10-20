import Foundation

extension BrowserContextMenuItem {
    /// The Chrome rows that Chrome on macOS draws with an icon by default
    /// (`render_view_context_menu.cc`: `AddItemWithIcon`, not behind
    /// `kMenuSimplification`), by Chromium command id, with the SF Symbol
    /// that stands in for Chrome's vector icon.
    static let chromeIcons: [Int: String] = [
        50161: "translate", // IDC_CONTENT_CONTEXT_TRANSLATE (kGTranslateIcon)
        50179: "translate", // IDC_CONTENT_CONTEXT_PARTIAL_TRANSLATE
        35011: "airplayvideo", // IDC_ROUTE_MEDIA, Cast… (kCastIcon)
    ]

    /// Pure: `items` (and their children) with the icon Chrome shows on its
    /// Translate and Cast rows; rows that already have an icon keep it.
    public static func withChromeIcons(_ items: [BrowserContextMenuItem]) -> [BrowserContextMenuItem] {
        items.map { item in
            var item = item
            if item.icon == nil, let symbol = chromeIcons[item.id] { item.icon = .symbol(symbol) }
            if !item.children.isEmpty { item.children = withChromeIcons(item.children) }
            return item
        }
    }
}
