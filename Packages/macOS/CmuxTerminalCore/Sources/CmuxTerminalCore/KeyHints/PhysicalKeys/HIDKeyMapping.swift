import Foundation

/// A key-to-key remap applied by macOS before apps see a key: `hidutil`'s
/// `UserKeyMapping`, or a keyboard's System Settings modifier keys.
///
/// Both store a list of `HIDKeyboardModifierMappingSrc` and
/// `HIDKeyboardModifierMappingDst` pairs, each a `page << 32 | usage`
/// value. A destination of ``PhysicalKey/noAction`` turns the key off.
public struct HIDKeyMapping: Sendable, Equatable {
    /// Destination for each remapped source key.
    public private(set) var destinations: [PhysicalKey: PhysicalKey]

    /// A mapping that changes nothing.
    public static let identity = HIDKeyMapping(destinations: [:])

    /// - Parameter destinations: Destination for each remapped source key.
    public init(destinations: [PhysicalKey: PhysicalKey]) {
        self.destinations = destinations.filter { $0.key != $0.value }
    }

    /// A mapping from source and destination `page << 32 | usage` pairs.
    ///
    /// - Parameter pairs: Source and destination usages, in the stored order.
    ///   A later pair for the same source wins.
    public init(pairs: [(source: UInt64, destination: UInt64)]) {
        var destinations: [PhysicalKey: PhysicalKey] = [:]
        for pair in pairs {
            destinations[PhysicalKey(hidUsage: pair.source)] = PhysicalKey(hidUsage: pair.destination)
        }
        self.init(destinations: destinations)
    }

    /// Parses `hidutil property --get UserKeyMapping` output.
    ///
    /// `hidutil` prints an old-style property list (`( { HIDKeyboardModifierMappingDst = 30064771113; HIDKeyboardModifierMappingSrc = 30064771129; } )`),
    /// or `(null)` when nothing is mapped. Each `{ }` entry is read for its
    /// source and destination in either order, decimal or hex; anything
    /// else yields no mapping.
    ///
    /// - Parameter hidutilOutput: The command's standard output.
    public init(hidutilOutput: String) {
        var pairs: [(source: UInt64, destination: UInt64)] = []
        for entry in hidutilOutput.split(separator: "}") {
            guard let source = Self.value(named: "HIDKeyboardModifierMappingSrc", in: entry),
                  let destination = Self.value(named: "HIDKeyboardModifierMappingDst", in: entry) else { continue }
            pairs.append((source, destination))
        }
        self.init(pairs: pairs)
    }

    /// A mapping from a stored array of pair dictionaries, as System
    /// Settings writes them to preferences. Entries without both numbers are
    /// skipped.
    ///
    /// - Parameter propertyList: The stored array value.
    public init(propertyList: Any) {
        var pairs: [(source: UInt64, destination: UInt64)] = []
        for entry in propertyList as? [Any] ?? [] {
            guard let entry = entry as? [String: Any],
                  let source = Self.number(entry["HIDKeyboardModifierMappingSrc"]),
                  let destination = Self.number(entry["HIDKeyboardModifierMappingDst"]) else { continue }
            pairs.append((source, destination))
        }
        self.init(pairs: pairs)
    }

    /// The key macOS delivers for `key`.
    public func output(for key: PhysicalKey) -> PhysicalKey {
        destinations[key] ?? key
    }

    /// This mapping followed by `next`.
    public func followed(by next: HIDKeyMapping) -> HIDKeyMapping {
        var destinations: [PhysicalKey: PhysicalKey] = [:]
        for key in Set(self.destinations.keys).union(next.destinations.keys) {
            destinations[key] = next.output(for: output(for: key))
        }
        return HIDKeyMapping(destinations: destinations)
    }

    private static func value(named name: String, in entry: Substring) -> UInt64? {
        guard let nameRange = entry.range(of: name) else { return nil }
        let rest = entry[nameRange.upperBound...].drop { $0 == " " || $0 == "\"" || $0 == "=" || $0 == ":" || $0.isWhitespace }
        let token = rest.prefix { $0.isHexDigit || $0 == "x" || $0 == "X" }
        if token.hasPrefix("0x") || token.hasPrefix("0X") {
            return UInt64(token.dropFirst(2), radix: 16)
        }
        return UInt64(token)
    }

    private static func number(_ value: Any?) -> UInt64? {
        if let number = value as? NSNumber { return number.uint64Value }
        if let text = value as? String { return UInt64(text) }
        return nil
    }
}
