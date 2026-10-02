public import CoreGraphics

/// Parses the pack's path data: absolute M, L, C and Z, numbers separated by
/// spaces or commas. Anything else (relative commands, arcs, quadratics)
/// returns nil.
public nonisolated enum IconPath {
    public static func cgPath(_ d: String) -> CGPath? {
        guard let tokens = tokens(d) else { return nil }
        let path = CGMutablePath()
        var command: Character?
        var args: [CGFloat] = []
        var started = false
        for token in tokens {
            if let letter = token.first, Self.commands.contains(letter) {
                guard args.isEmpty else { return nil }
                command = letter
                if letter == "Z" {
                    guard started else { return nil }
                    path.closeSubpath()
                }
                continue
            }
            guard let current = command, current != "Z", let value = Double(token) else { return nil }
            args.append(CGFloat(value))
            guard args.count == (current == "C" ? 6 : 2) else { continue }
            func point(_ i: Int) -> CGPoint { CGPoint(x: args[i], y: args[i + 1]) }
            switch current {
            case "M":
                path.move(to: point(0))
                started = true
                command = "L"
            case "L":
                guard started else { return nil }
                path.addLine(to: point(0))
            default:
                guard started else { return nil }
                path.addCurve(to: point(4), control1: point(0), control2: point(2))
            }
            args.removeAll(keepingCapacity: true)
        }
        return started && args.isEmpty ? path : nil
    }

    private static let commands: Set<Character> = ["M", "L", "C", "Z"]

    /// Splits path data into command letters and number strings.
    private static func tokens(_ d: String) -> [String]? {
        var tokens: [String] = []
        var number = ""
        func flush() {
            if !number.isEmpty { tokens.append(number) }
            number = ""
        }
        for character in d {
            switch character {
            case "M", "L", "C", "Z":
                flush()
                tokens.append(String(character))
            case " ", ",", "\t", "\n", "\r":
                flush()
            case "-" where !(number.last == "e" || number.last == "E"):
                flush()
                number.append(character)
            case "0"..."9", ".", "-", "+", "e", "E":
                number.append(character)
            default:
                return nil
            }
        }
        flush()
        return tokens
    }
}
