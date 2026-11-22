import Foundation

/// `#RRGGBB` (or `#RRGGBBAA`) text for a colour: how cmux.json, the CLI and the chat colour store write it.
extension HomeColor: Codable {
    /// A colour from `#RRGGBB`, `RRGGBB`, `#RRGGBBAA` or `#RGB` text; nil for anything else.
    /// - Parameter hex: the colour's hex text.
    public init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        if text.count == 3 { text = text.map { "\($0)\($0)" }.joined() }
        guard text.count == 6 || text.count == 8, let value = UInt64(text, radix: 16) else { return nil }
        let bytes = text.count == 8 ? value : value << 8 | 0xFF
        func byte(_ shift: UInt64) -> CGFloat { CGFloat((bytes >> shift) & 0xFF) / 255 }
        self.init(red: byte(24), green: byte(16), blue: byte(8), alpha: byte(0))
    }

    /// `#RRGGBB`, with `AA` appended only when the colour is not opaque.
    public var hex: String {
        func byte(_ c: CGFloat) -> Int { Int(exactly: (max(0, min(1, c)) * 255).rounded()) ?? 0 }
        let rgb = String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
        return byte(alpha) == 255 ? rgb : rgb + String(format: "%02X", byte(alpha))
    }

    public init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let color = HomeColor(hex: text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "expected #RRGGBB, got \(text)"))
        }
        self = color
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }
}
