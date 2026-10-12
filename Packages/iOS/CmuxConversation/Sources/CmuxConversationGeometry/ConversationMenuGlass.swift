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
