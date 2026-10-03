public import CoreGraphics

/// An sRGB colour as plain numbers (Sendable and hashable, so it can key the
/// bitmap cache and live in a static default).
public struct HomeColor: Hashable, Sendable {
    public var red: CGFloat
    public var green: CGFloat
    public var blue: CGFloat
    public var alpha: CGFloat

    public init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// 0...255 components.
    public static func rgb255(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, alpha: CGFloat = 1) -> HomeColor {
        HomeColor(red: r / 255, green: g / 255, blue: b / 255, alpha: alpha)
    }

    public static func gray255(_ w: CGFloat, alpha: CGFloat = 1) -> HomeColor { rgb255(w, w, w, alpha: alpha) }

    public var cgColor: CGColor { CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }

    func with(alpha: CGFloat) -> HomeColor { HomeColor(red: red, green: green, blue: blue, alpha: alpha) }
}

/// Every colour the renderer draws. Hosts pass their own (for example derived
/// from the terminal theme); `standard` and `standardInactive` are the
/// measured dark palette of the reference design.
public struct HomePalette: Hashable, Sendable {
    public var background: HomeColor
    public var incomingBubble: HomeColor
    public var incomingText: HomeColor
    public var outgoingText: HomeColor
    public var secondaryText: HomeColor
    public var failure: HomeColor
    public var badge: HomeColor
    /// Outgoing bubbles shade with their position in the viewport: stops at
    /// fractions of the viewport height, top to bottom.
    public var outgoingGradient: [GradientStop]
    public var caret: HomeColor
    public var caretAfterSend: HomeColor
    public var composeGlass: HomeColor
    public var placeholder: HomeColor
    /// The grey under the flying bubble while it is translucent (the field's glass).
    public var morphUnderlay: HomeColor
    public var typingDot: HomeColor
    public var typingDotHighlight: HomeColor

    public struct GradientStop: Hashable, Sendable {
        public var location: CGFloat
        public var color: HomeColor

        public init(location: CGFloat, color: HomeColor) {
            self.location = location
            self.color = color
        }
    }

    /// (y in 2x pixels of a 1041 pt tall viewport, red, green), measured from bubble centers.
    private static let measuredStops: [(CGFloat, CGFloat, CGFloat)] = [
        (0, 43, 141), (400, 42, 140.5), (540, 41, 140), (800, 36.5, 139), (1200, 28.5, 136.6), (1490, 20, 135),
        (1600, 15.3, 134.3), (1800, 6.9, 133.1), (1900, 2, 132.5), (1960, 0, 132), (2082, 0, 132),
    ]

    private static func stops(blue: CGFloat, transform: (CGFloat, CGFloat) -> (CGFloat, CGFloat)) -> [GradientStop] {
        measuredStops.map { y, r, g in
            let (red, green) = transform(r, g)
            return GradientStop(location: y / 2082, color: .rgb255(red, green, blue))
        }
    }

    public static let standard = HomePalette(
        background: .gray255(25),
        incomingBubble: .gray255(49),
        incomingText: .gray255(220),
        outgoingText: .gray255(255),
        secondaryText: .gray255(148),
        failure: HomeColor(red: 1, green: 0.27, blue: 0.23),
        badge: .rgb255(59, 59, 61),
        outgoingGradient: stops(blue: 253) { ($0, $1) },
        caret: HomeColor(red: 0.04, green: 0.52, blue: 1),
        caretAfterSend: .gray255(127.5),
        composeGlass: .gray255(49),
        placeholder: .gray255(110),
        morphUnderlay: .gray255(51),
        typingDot: .gray255(82),
        typingDotHighlight: .gray255(123)
    )

    /// The palette of a window that is not key.
    public static let standardInactive: HomePalette = {
        var p = standard
        p.background = .gray255(30)
        p.incomingBubble = .gray255(59)
        p.badge = .gray255(59)
        p.outgoingGradient = stops(blue: 248) { (0.5 * $0 + 61, 0.67 * $1 + 57) }
        return p
    }()

    /// The outgoing colour at a fraction of the viewport height.
    func outgoing(at fraction: CGFloat) -> HomeColor {
        let s = outgoingGradient
        guard let first = s.first else { return .gray255(0) }
        guard s.count > 1 else { return first.color }
        var i = 1
        while i < s.count - 1, s[i].location < fraction { i += 1 }
        let a = s[i - 1], b = s[i]
        let f = max(0, min(1, (fraction - a.location) / max(1e-6, b.location - a.location)))
        func mix(_ x: CGFloat, _ y: CGFloat) -> CGFloat { x + (y - x) * f }
        return HomeColor(red: mix(a.color.red, b.color.red), green: mix(a.color.green, b.color.green),
                         blue: mix(a.color.blue, b.color.blue), alpha: mix(a.color.alpha, b.color.alpha))
    }
}
