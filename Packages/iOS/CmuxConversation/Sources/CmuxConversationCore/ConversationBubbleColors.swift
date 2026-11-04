import Foundation

/// An sRGB colour a person picked for a chat (Chat Colors), kept as `#RRGGBB`.
public struct ConversationColor: Hashable, Sendable, Codable {
    public var red: Double
    public var green: Double
    public var blue: Double

    /// Components from 0 to 1, clamped and kept to 8 bits each (what `#RRGGBB`
    /// holds), so a colour equals itself after it is saved and read back.
    public init(red: Double, green: Double, blue: Double) {
        func channel(_ value: Double) -> Double { (min(max(value, 0), 1) * 255).rounded() / 255 }
        self.red = channel(red)
        self.green = channel(green)
        self.blue = channel(blue)
    }

    /// `#RRGGBB` (or `RRGGBB`); nil for anything else.
    public init?(hex: String) {
        var digits = hex.trimmingCharacters(in: .whitespaces)
        if digits.hasPrefix("#") { digits.removeFirst() }
        guard digits.count == 6, digits.allSatisfy(\.isHexDigit), let value = UInt32(digits, radix: 16) else { return nil }
        self.init(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }

    /// `#RRGGBB`, upper case.
    public var hex: String {
        let parts = [red, green, blue].map { Int(($0 * 255).rounded()) }
        return String(format: "#%02X%02X%02X", parts[0], parts[1], parts[2])
    }

    public static let white = ConversationColor(red: 1, green: 1, blue: 1)
    public static let black = ConversationColor(red: 0, green: 0, blue: 0)

    /// WCAG relative luminance.
    public var luminance: Double {
        func linear(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// The WCAG contrast ratio between this colour and `other` (1 to 21).
    public func contrast(with other: ConversationColor) -> Double {
        let (a, b) = (luminance, other.luminance)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// White or black, whichever has the higher contrast on this colour: the
    /// Mac's automatic text for a chosen bubble colour (`HomeColor.strongestText`).
    public var readableText: ConversationColor {
        contrast(with: .white) >= contrast(with: .black) ? .white : .black
    }

    /// This colour as JSON writes it: `"#RRGGBB"`.
    public init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let color = ConversationColor(hex: text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not a #RRGGBB colour: \(text)"))
        }
        self = color
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }
}

/// One chat's own bubble colours (the Mac's Chat Colors…, `HomeBubbleColors`): each nil keeps
/// the conversation's own look. A fill without a text colour gets white or black text, whichever
/// reads on it; a text colour the person sets is kept as set.
public struct ConversationBubbleColors: Hashable, Sendable, Codable {
    /// My bubbles' fill; nil keeps Messages' blue.
    public var sent: ConversationColor?
    /// My bubbles' text; nil picks white or black for ``sent``.
    public var sentText: ConversationColor?
    /// The other side's bubbles' fill; nil keeps the grey.
    public var received: ConversationColor?
    /// The other side's text; nil picks white or black for ``received``.
    public var receivedText: ConversationColor?

    public init(sent: ConversationColor? = nil, sentText: ConversationColor? = nil,
                received: ConversationColor? = nil, receivedText: ConversationColor? = nil) {
        self.sent = sent
        self.sentText = sentText
        self.received = received
        self.receivedText = receivedText
    }

    /// No colour chosen: the conversation draws as it does without any.
    public var isEmpty: Bool { sent == nil && sentText == nil && received == nil && receivedText == nil }

    /// My text as drawn: the chosen one, else one that reads on a chosen fill; nil keeps the default.
    public var resolvedSentText: ConversationColor? { sentText ?? sent?.readableText }
    /// Their text as drawn: the chosen one, else one that reads on a chosen fill; nil keeps the default.
    public var resolvedReceivedText: ConversationColor? { receivedText ?? received?.readableText }

    /// The Mac's swatches (HomeChatColorsView): my bubbles, then theirs.
    public static let sentSwatches: [ConversationColor] = ["#0A84FF", "#34C759", "#AF52DE", "#FF2D55", "#FF9500", "#FFD60A", "#30B0C7", "#8E8E93"]
        .compactMap(ConversationColor.init(hex:))
    public static let receivedSwatches: [ConversationColor] = ["#E9E9EB", "#3B3B3D", "#D6EAFF", "#D9F7E0", "#EADCF8", "#FFE5CC", "#1C2A4A"]
        .compactMap(ConversationColor.init(hex:))
}
