import CmuxFuzzSupport
import CmuxNextSettings
import Foundation

/// A message body as an engine hands it to the host (`WKScriptMessage.body`, a CEF binding's parsed payload):
/// `NSNull`, `NSNumber` (booleans, integers, doubles, the non-finite ones JavaScript has), strings, arrays and
/// dictionaries as Foundation or Swift collections, and the values no JSON holds (a `Date`, as WebKit gives for
/// a JavaScript `Date`, and `Data`). Dictionaries may hold the composed and the decomposed accent as two keys
/// (two `NSString`s that Swift reads as one string) or a key that is no string.
nonisolated indirect enum PageFuzzBody {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case date
    case data
    case array([PageFuzzBody], ns: Bool)
    /// Members in order; a nil key is a number key (only in an `NSDictionary`).
    case object([(key: String?, value: PageFuzzBody)], ns: Bool)

    /// Keys of a dictionary body: an envelope's own fields among others, and the composed and decomposed é.
    static let keys = ["t", "id", "op", "params", "a", "\u{E9}", "e\u{301}", "ready", "x"]

    static func random(_ rng: inout FuzzRNG, depth: Int = 3) -> PageFuzzBody {
        switch rng.below(depth > 0 ? 12 : 8) {
        case 0: return .null
        case 1: return .bool(rng.bool())
        case 2: return .int(rng.oneIn(4) ? (rng.bool() ? Int64.max : Int64.min) : Int64(rng.int(in: -1_000...1_000)))
        case 3:
            let special: [Double] = [Double.infinity, -Double.infinity, Double.nan, 1e300, -0.0, 9_007_199_254_740_993, 0.5]
            return .double(rng.oneIn(2) ? (rng.element(of: special) ?? 0) : rng.double(in: -1e6...1e6))
        case 4: return .string(rng.oneIn(16) ? FuzzText.hugeLine(bytes: 1 << rng.int(in: 10...18), &rng) : FuzzJSON.randomString(&rng))
        case 5: return .date
        case 6: return .data
        case 7: return .string(rng.element(of: keys) ?? "")
        case 8, 9: return .array((0..<rng.below(4)).map { _ in random(&rng, depth: depth - 1) }, ns: rng.bool())
        default: return object(&rng, depth: depth - 1)
        }
    }

    /// A dictionary of distinct keys (`keys`, a number key one time in sixteen for an `NSDictionary`).
    static func object(_ rng: inout FuzzRNG, depth: Int) -> PageFuzzBody {
        let ns = rng.bool()
        var pool = keys
        var members: [(key: String?, value: PageFuzzBody)] = []
        for _ in 0..<rng.below(5) where !pool.isEmpty {
            let key = pool.remove(at: rng.below(pool.count))
            members.append((key: Optional(key), value: random(&rng, depth: depth)))
        }
        if ns, rng.oneIn(16) { members.append((key: nil, value: .null)) }
        return .object(members, ns: ns)
    }

    /// The value an engine hands over.
    var foundation: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let value): return NSNumber(value: value)
        case .int(let value): return NSNumber(value: value)
        case .double(let value): return NSNumber(value: value)
        case .string(let value): return value
        case .date: return Date(timeIntervalSince1970: 0)
        case .data: return Data([1, 2, 3])
        case .array(let items, let ns):
            let values = items.map(\.foundation)
            if ns { return NSArray(array: values) }
            return values
        case .object(let members, let ns):
            guard ns else {
                var dictionary: [String: Any] = [:]
                for member in members {
                    if let key = member.key { dictionary[key] = member.value.foundation }
                }
                return dictionary
            }
            let dictionary = NSMutableDictionary()
            for member in members {
                if let key = member.key {
                    dictionary.setObject(member.value.foundation, forKey: NSString(string: key))
                } else {
                    dictionary.setObject(member.value.foundation, forKey: NSNumber(value: 7))
                }
            }
            return dictionary
        }
    }

    /// What `JSONValue(foundation:)` must give: refused (nil) when a date, data or a number key is anywhere;
    /// else a value, `exact` when it is fixed (not when a NaN or two keys Swift reads as one are in it).
    var bridged: (accepted: Bool, exact: JSONValue?) {
        switch self {
        case .null: return (true, .null)
        case .bool(let value): return (true, .bool(value))
        case .int(let value): return (true, .number(Double(value)))
        case .double(let value): return (true, value.isNaN ? nil : .number(value))
        case .string(let value): return (true, .string(value))
        case .date, .data: return (false, nil)
        case .array(let items, _):
            let parts = items.map(\.bridged)
            guard parts.allSatisfy(\.accepted) else { return (false, nil) }
            let exact = parts.compactMap(\.exact)
            return (true, exact.count == parts.count ? .array(exact) : nil)
        case .object(let members, let ns):
            let parts = Self.members(members, ns: ns).map { ($0.key, $0.value.bridged) }
            guard parts.allSatisfy({ $0.0 != nil && $0.1.accepted }) else { return (false, nil) }
            var exact: [String: JSONValue] = [:]
            var fixed = true
            for (key, part) in parts {
                guard let key, let value = part.exact else {
                    fixed = false
                    continue
                }
                // Two NSString keys Swift reads as one string: the dictionary's order picks the member.
                if ns, exact[key] != nil { fixed = false }
                exact[key] = value
            }
            return (true, fixed ? .object(exact) : nil)
        }
    }

    /// Whether `JSONSerialization` can write the value (`isValidJSONObject` of it in an array).
    var serializable: Bool {
        switch self {
        case .null, .bool, .int, .string: return true
        case .double(let value): return value.isFinite
        case .date, .data: return false
        case .array(let items, _): return items.allSatisfy(\.serializable)
        case .object(let members, let ns): return Self.members(members, ns: ns).allSatisfy { $0.key != nil && $0.value.serializable }
        }
    }

    /// The members the engine's dictionary holds: all of an `NSDictionary`'s; a Swift dictionary drops number
    /// keys and keeps the later of two keys that are equal Swift strings.
    static func members(_ members: [(key: String?, value: PageFuzzBody)], ns: Bool) -> [(key: String?, value: PageFuzzBody)] {
        guard !ns else { return members }
        var kept: [(key: String?, value: PageFuzzBody)] = []
        for member in members where member.key != nil {
            kept.removeAll { $0.key == member.key }
            kept.append(member)
        }
        return kept
    }
}
