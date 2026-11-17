/// The tint a menu's regular glass carries so it reads as Messages' own.
public struct ConversationMenuGlassTint: Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// No tint: the plain regular glass.
    public static let none = ConversationMenuGlassTint(red: 0, green: 0, blue: 0, alpha: 0)
}

extension ConversationMenuGlassTint {
    /// The long-press menu in light mode on iOS 26. Messages' menu is a
    /// UIKit context-menu platter: 237,237,239 over its 206,206,210 veil
    /// (iOS 26.5), where a plain regular glass of the menu's size reads
    /// 239,239,242. This faint warm-gray tint lands on 237,237,239 (fitted
    /// in a glass probe at 250 x 260 pt; the blue channel moves ~1.5 levels
    /// per 0.001 of tint blue, so keep all four digits).
    public static let longPressLightIOS26 = ConversationMenuGlassTint(red: 0.94, green: 0.94, blue: 0.938, alpha: 0.3)
}

extension ConversationMenuGlassTint {
    /// The long-press menu in light mode on iOS 27. Messages' platter reads
    /// 230,230,230 over its neutral 204 veil (iOS 27.0), where a plain
    /// regular glass of our menu's size reads 237; a 9 % mid-gray tint
    /// lands on 230 (glass probe at 250 x 241 pt). Dark mode already matches
    /// (32 on both).
    public static let longPressLightIOS27 = ConversationMenuGlassTint(red: 0.5, green: 0.5, blue: 0.5, alpha: 0.09)
}

/// Where Messages' long-press menu (a UIKit context menu) sits and how much
/// it dims what is behind it.
// lint:allow namespace-type -- vendored CmuxConversation snapshot
public enum MessageMenuGeometry {
    /// The menu and the lifted bubble keep the system's minimum side margin
    /// from the screen: 16 pt on a 402 pt iPhone 17 Pro (iOS 26.5 and 27.0:
    /// an outgoing bubble's 250 pt menu spans 136...386), 20 pt on a 440 pt
    /// Pro Max (170...420).
    public static let defaultScreenInset: Double = 16

    /// The menu's x: under the bubble's trailing edge (outgoing) or leading
    /// edge (incoming), kept on screen.
    public static func menuX(previewMinX: Double, previewMaxX: Double, isOutgoing: Bool, width: Double, menuWidth: Double, inset: Double = defaultScreenInset) -> Double {
        let x = isOutgoing ? previewMaxX - menuWidth : previewMinX
        return min(max(inset, x), width - inset - menuWidth)
    }

    /// iOS 27's neutral black veil: light white -> 204; dark the transcript
    /// and header fall to ~0.52 of their brightness.
    public static func neutralVeilAlpha(dark: Bool) -> Double { dark ? 0.48 : 0.2 }
}
