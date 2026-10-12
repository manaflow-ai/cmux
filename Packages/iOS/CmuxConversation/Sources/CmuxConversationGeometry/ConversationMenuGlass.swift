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
    /// The long-press menu in light mode on iOS 26.
    public static let longPressLightIOS26 = ConversationMenuGlassTint.none
}
