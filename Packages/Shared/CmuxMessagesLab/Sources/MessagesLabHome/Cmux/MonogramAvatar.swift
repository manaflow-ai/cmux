import AppKit

/// An iMessage-style monogram avatar: up to two white letters on a grey top-to-bottom gradient disc.
///
/// Lawrence 2026-10-30 (msg 17682): "just maybe CH for chief? like in imessage. no profile pic by
/// default." A Chief or person with no picture of its own wears this in Home's header, the
/// first-run hero and anywhere else a monogram is drawn from a name.
///
/// ```swift
/// MonogramAvatar(name: "Chief").initials       // "CH"
/// MonogramAvatar(name: "Scout Two").initials   // "ST"
/// let image = MonogramAvatar(name: "Chief").image(side: 40, light: false)
/// ```
public struct MonogramAvatar: Hashable, Sendable {
    /// The letters drawn on the disc (one or two characters, uppercased).
    public let initials: String

    /// A monogram of letters already chosen (a profile's own text avatar).
    /// - Parameter initials: The letters to draw, uppercased as given.
    public init(initials: String) {
        self.initials = initials
    }

    /// A monogram of `name`'s initials: the first letters of its first two words, else the first two
    /// characters of its one word ("Chief" is "CH"), else "?".
    /// - Parameter name: The Chief's or person's shown name.
    public init(name: String) {
        let words = name.split(whereSeparator: { $0.isWhitespace || $0 == "-" || $0 == "_" })
            .filter { $0.contains(where: { $0.isLetter || $0.isNumber }) }
        let letters: String = switch words.count {
        case 0: "?"
        case 1: String(words[0].filter { $0.isLetter || $0.isNumber }.prefix(2))
        default: String(words.prefix(2).compactMap { $0.first(where: { $0.isLetter || $0.isNumber }) })
        }
        initials = letters.uppercased()
    }

    /// Whether `text` draws as a monogram (letters and digits only), not as an emoji on a disc.
    /// - Parameter text: A text avatar.
    /// - Returns: True for one or more letters or digits, false for empty text or anything else.
    public static func isMonogram(_ text: String) -> Bool {
        !text.isEmpty && text.allSatisfy { $0.isLetter || $0.isNumber }
    }

    /// The disc's gradient, top then bottom: Messages' monogram greys, a step darker in dark mode so
    /// the disc does not glow on a dark chat.
    static func gradient(light: Bool) -> (top: NSColor, bottom: NSColor) {
        light
            ? (NSColor(srgbRed: 0.663, green: 0.678, blue: 0.725, alpha: 1), NSColor(srgbRed: 0.525, green: 0.541, blue: 0.592, alpha: 1))
            : (NSColor(srgbRed: 0.553, green: 0.565, blue: 0.608, alpha: 1), NSColor(srgbRed: 0.408, green: 0.420, blue: 0.459, alpha: 1))
    }

    /// The monogram drawn in a `side`-point circle.
    /// - Parameters:
    ///   - side: The circle's diameter in points.
    ///   - light: A light appearance (the lighter greys).
    /// - Returns: An image that redraws at the screen's scale.
    public func image(side: CGFloat, light: Bool) -> NSImage {
        let initials = initials
        let colors = Self.gradient(light: light)
        return NSImage(size: NSSize(width: side, height: side), flipped: true) { r in
            NSBezierPath(ovalIn: r).addClip()
            NSGradient(starting: colors.top, ending: colors.bottom)?.draw(in: r, angle: 90)
            let font = HomeFonts.system(ofSize: side * (initials.count > 1 ? 0.4 : 0.46), weight: .medium)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
            let size = (initials as NSString).size(withAttributes: attrs)
            (initials as NSString).draw(at: CGPoint(x: r.midX - size.width / 2, y: r.midY - size.height / 2), withAttributes: attrs)
            return true
        }
    }
}
