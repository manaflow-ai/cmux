import Foundation

/// An sRGB colour as CSS writes it in an SVG document (0...1 components).
nonisolated struct SVGColor: Hashable, Sendable {
    var red: Double
    var green: Double
    var blue: Double

    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// `#rgb`, `#rrggbb`, `#rrggbbaa` (alpha ignored), `rgb(r, g, b)`, `white` or `black`; nil otherwise.
    init?(css: String) {
        let text = css.trimmingCharacters(in: .whitespaces).lowercased()
        switch text {
        case "white": self.init(red: 1, green: 1, blue: 1); return
        case "black": self.init(red: 0, green: 0, blue: 0); return
        default: break
        }
        if text.hasPrefix("#") {
            var digits = Array(text.dropFirst())
            if digits.count == 3 || digits.count == 4 { digits = digits.prefix(3).flatMap { [$0, $0] } }
            guard digits.count == 6 || digits.count == 8, let value = UInt32(String(digits.prefix(6)), radix: 16) else { return nil }
            self.init(red: Double((value >> 16) & 0xff) / 255, green: Double((value >> 8) & 0xff) / 255, blue: Double(value & 0xff) / 255)
            return
        }
        guard text.hasPrefix("rgb("), text.hasSuffix(")") else { return nil }
        let numbers = text.dropFirst(4).dropLast().split { $0 == "," || $0 == " " }.compactMap { Double($0) }
        guard numbers.count >= 3 else { return nil }
        self.init(red: numbers[0] / 255, green: numbers[1] / 255, blue: numbers[2] / 255)
    }

    /// `#rrggbb`.
    var hex: String {
        func byte(_ c: Double) -> Int { Int((max(0, min(1, c)) * 255).rounded()) }
        return String(format: "#%02x%02x%02x", byte(red), byte(green), byte(blue))
    }
}
