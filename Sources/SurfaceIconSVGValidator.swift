import CoreGraphics
import Foundation

/// Validates a deliberately small, resource-bounded SVG dialect before SwiftDraw sees it.
struct SurfaceIconSVGValidator {
    enum ValidationError: Error, Equatable {
        case invalidSVG
    }

    func validate(_ source: String) throws {
        guard !source.isEmpty, source.utf8.count <= 16 * 1024,
              !source.contains("<!"), !source.contains("<?"), !source.contains("&") else {
            throw ValidationError.invalidSVG
        }
        let delegate = SurfaceIconSVGDocumentParser(validator: self)
        let parser = XMLParser(data: Data(source.utf8))
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        parser.delegate = delegate
        guard parser.parse(), delegate.isValidDocument else { throw ValidationError.invalidSVG }
    }

    func numbers(_ source: String, limit: Double = 10_000) -> [Double]? {
        guard let tokens = tokens(source, commands: false), !tokens.isEmpty else { return nil }
        let values = tokens.compactMap(Double.init)
        guard values.count == tokens.count,
              values.allSatisfy({ $0.isFinite && abs($0) <= limit }) else { return nil }
        return values
    }

    func validPath(_ source: String) -> Bool {
        guard let tokens = tokens(source, commands: true), !tokens.isEmpty, tokens.count <= 4096,
              tokens[0] == "M" || tokens[0] == "m" else { return false }
        let arities: [String: Int] = ["m": 2, "l": 2, "h": 1, "v": 1, "c": 6,
                                      "s": 4, "q": 4, "t": 2, "a": 7, "z": 0]
        var index = 0
        while index < tokens.count {
            let command = tokens[index].lowercased()
            guard let arity = arities[command] else { return false }
            index += 1
            let start = index
            while index < tokens.count, Double(tokens[index]) != nil { index += 1 }
            let count = index - start
            if arity == 0 {
                guard count == 0 else { return false }
                continue
            }
            guard count >= arity, count % arity == 0 else { return false }
            for offset in 0..<count {
                guard let value = Double(tokens[start + offset]), value.isFinite, abs(value) <= 10_000 else {
                    return false
                }
                if command == "a" {
                    if offset % 7 == 0 || offset % 7 == 1, value < 0 { return false }
                    if offset % 7 == 3 || offset % 7 == 4,
                       tokens[start + offset] != "0", tokens[start + offset] != "1" { return false }
                }
            }
        }
        return true
    }

    func validTransform(_ source: String) -> Bool {
        let pattern = #"(translate|rotate|scale)\s*\(([^()]*)\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let ns = source as NSString
        let matches = regex.matches(in: source, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty, matches.count <= 32 else { return false }
        var end = 0
        var combined = CGAffineTransform.identity
        for match in matches {
            let gap = ns.substring(with: NSRange(location: end, length: match.range.location - end))
            guard gap.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let args = numbers(ns.substring(with: match.range(at: 2))) else { return false }
            let operation: CGAffineTransform
            switch ns.substring(with: match.range(at: 1)) {
            case "translate":
                guard (1...2).contains(args.count), args.allSatisfy({ abs($0) <= 128 }) else { return false }
                operation = CGAffineTransform(translationX: args[0], y: args.count == 2 ? args[1] : 0)
            case "scale":
                guard (1...2).contains(args.count), args.allSatisfy({ abs($0) <= 10 }) else { return false }
                operation = CGAffineTransform(scaleX: args[0], y: args.count == 2 ? args[1] : args[0])
            case "rotate":
                guard args.count == 1 || args.count == 3, abs(args[0]) <= 3600,
                      args.dropFirst().allSatisfy({ abs($0) <= 128 }) else { return false }
                let x = args.count == 3 ? args[1] : 0
                let y = args.count == 3 ? args[2] : 0
                operation = CGAffineTransform(translationX: x, y: y)
                    .rotated(by: args[0] * .pi / 180).translatedBy(x: -x, y: -y)
            default: return false
            }
            combined = combined.concatenating(operation)
            guard [combined.a, combined.b, combined.c, combined.d].allSatisfy({ $0.isFinite && abs($0) <= 10 }),
                  [combined.tx, combined.ty].allSatisfy({ $0.isFinite && abs($0) <= 128 }) else { return false }
            end = NSMaxRange(match.range)
        }
        return ns.substring(from: end).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func tokens(_ source: String, commands: Bool) -> [String]? {
        // Limit exponent spelling as well as numeric magnitude; never feed huge exponents to the renderer.
        let number = #"[-+]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][-+]?[0-9]{1,2})?"#
        let pattern = commands ? "[MmLlHhVvCcSsQqTtAaZz]|" + number : number
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = source as NSString
        let matches = regex.matches(in: source, range: NSRange(location: 0, length: ns.length))
        var end = 0
        var result: [String] = []
        for match in matches {
            let gap = ns.substring(with: NSRange(location: end, length: match.range.location - end))
            let trimmed = gap.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty || (trimmed == "," && !result.isEmpty && Double(result.last!) != nil) else {
                return nil
            }
            let token = ns.substring(with: match.range)
            if trimmed == ",", Double(token) == nil { return nil }
            // Adjacent numbers require a sign or decimal point boundary (e.g. 10-2 or .5.6).
            if gap.isEmpty, let previous = result.last, Double(previous) != nil, Double(token) != nil,
               !token.hasPrefix("-"), !token.hasPrefix("+"), !token.hasPrefix(".") { return nil }
            result.append(token)
            end = NSMaxRange(match.range)
        }
        guard ns.substring(from: end).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return result
    }
}
