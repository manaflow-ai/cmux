public import Foundation

/// The calculator row's arithmetic (plans/cmux-next/omnibar-suggestions.md,
/// "Sources"): `+ - * / % ^`, `×` and `÷`, parentheses, unary minus and
/// decimals, by recursive descent. Pure. Input that is not a whole
/// expression with at least one operator (a plain number, a word) gives nil.
public nonisolated struct OmniboxCalculator {
    public init() {}

    /// The value of `text`, or nil.
    public static func evaluate(_ text: String) -> Double? {
        var parser = Parser(text)
        guard let value = parser.parse(), value.isFinite else { return nil }
        return value
    }

    /// The answer as shown and copied: an integer without a fraction, else
    /// up to 10 significant digits ("0.3333333333").
    public static func format(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.usesSignificantDigits = true
        formatter.maximumSignificantDigits = 10
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    /// The answer row for `text`, or nil when it is not arithmetic. Enter
    /// on it copies the answer; it never navigates or completes inline.
    public static func row(for text: String) -> BrowserSuggestion? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf16.count <= 256, let value = evaluate(trimmed) else { return nil }
        let answer = format(value)
        guard answer != trimmed, let url = URL(string: "cmux-answer:" + (answer.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "0")) else {
            return nil
        }
        var row = BrowserSuggestion(kind: .answer, title: "= " + answer, detail: Strings.calculatorCopyHint, url: url, score: 999)
        row.content = answer
        row.inlineCompletable = false
        return row
    }

    /// Recursive descent: sum := product (('+'|'-') product)*;
    /// product := power (('*'|'/'|'%') power)*; power := unary ('^' power)?;
    /// unary := '-' unary | '+' unary | atom; atom := number | '(' sum ')'.
    struct Parser {
        private let characters: [Character]
        private var index = 0
        private var operators = 0

        init(_ text: String) {
            characters = text.filter { !$0.isWhitespace }.map { (character: Character) -> Character in
                switch character {
                case "×": "*"
                case "÷": "/"
                default: character
                }
            }
        }

        mutating func parse() -> Double? {
            guard !characters.isEmpty, let value = sum(), index == characters.count, operators > 0 else { return nil }
            return value
        }

        private var next: Character? { index < characters.count ? characters[index] : nil }

        private mutating func sum() -> Double? {
            guard var value = product() else { return nil }
            while let op = next, op == "+" || op == "-" {
                index += 1
                operators += 1
                guard let rhs = product() else { return nil }
                value = op == "+" ? value + rhs : value - rhs
            }
            return value
        }

        private mutating func product() -> Double? {
            guard var value = power() else { return nil }
            while let op = next, op == "*" || op == "/" || op == "%" {
                index += 1
                operators += 1
                guard let rhs = power() else { return nil }
                switch op {
                case "*": value *= rhs
                case "/": value /= rhs
                default: value = value.truncatingRemainder(dividingBy: rhs)
                }
            }
            return value
        }

        private mutating func power() -> Double? {
            guard let base = unary() else { return nil }
            guard next == "^" else { return base }
            index += 1
            operators += 1
            guard let exponent = power() else { return nil }
            return pow(base, exponent)
        }

        private mutating func unary() -> Double? {
            if next == "-" || next == "+" {
                let negative = next == "-"
                index += 1
                return unary().map { negative ? -$0 : $0 }
            }
            return atom()
        }

        private mutating func atom() -> Double? {
            if next == "(" {
                index += 1
                guard let value = sum(), next == ")" else { return nil }
                index += 1
                return value
            }
            let start = index
            while let character = next, character.isASCII, character.isNumber || character == "." { index += 1 }
            guard index > start else { return nil }
            return Double(String(characters[start..<index]))
        }
    }
}
