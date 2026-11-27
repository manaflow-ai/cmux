public import Foundation

/// Hand-off text for tuned values: give it to an agent to bake the values
/// into the code defaults, then reset the overrides.
public nonisolated enum TunableExport {
    /// One changed tunable: its descriptor, its current and default values.
    public struct Change: Sendable {
        public let descriptor: TunableDescriptor
        public let value: TunableValue
        public let defaultValue: TunableValue

        public init(descriptor: TunableDescriptor, value: TunableValue, defaultValue: TunableValue) {
            self.descriptor = descriptor
            self.value = value
            self.defaultValue = defaultValue
        }
    }

    /// Overrides that differ from their defaults, in section then key order.
    @MainActor
    public static func changes(descriptors: [TunableDescriptor], overrides: [String: TunableValue]) -> [Change] {
        descriptors.compactMap { descriptor -> Change? in
            guard let value = overrides[descriptor.key] else { return nil }
            let defaultValue = descriptor.defaultValue
            return value == defaultValue ? nil : Change(descriptor: descriptor, value: value, defaultValue: defaultValue)
        }
        .sorted { ($0.descriptor.section.order, $0.descriptor.key) < ($1.descriptor.section.order, $1.descriptor.key) }
    }

    /// `{"key": value}` of the changes, pretty-printed with sorted keys.
    public static func json(_ changes: [Change]) -> String {
        TunableFile.object(Dictionary(changes.map { ($0.descriptor.key, $0.value) }, uniquingKeysWith: { first, _ in first }))
    }

    /// One line per change, `<Swift name>: <Swift literal>`, with a comment
    /// naming the tunable and its old default.
    public static func swiftDefaults(_ changes: [Change]) -> String {
        guard !changes.isEmpty else { return "// No tunable differs from its default." }
        var lines = ["// cmux-next Debug Settings: tuned defaults. Replace each default in code, then reset the overrides."]
        for change in changes {
            let descriptor = change.descriptor
            lines.append("// \(descriptor.section.title) > \(descriptor.label) (\(descriptor.key)), was \(swiftLiteral(change.defaultValue))")
            lines.append("\(descriptor.codeName ?? descriptor.key): \(swiftLiteral(change.value))")
        }
        return lines.joined(separator: "\n")
    }

    /// A Swift literal for `value` (`0.25`, `true`, `.insetCard`,
    /// `SpringParameters(response: 0.2, dampingFraction: 0.9)`).
    public static func swiftLiteral(_ value: TunableValue) -> String {
        switch value {
        case .number(let number): format(number)
        case .bool(let flag): flag ? "true" : "false"
        case .choice(let raw): "." + raw
        case .color(let color): "." + color.rawValue
        case .spring(let spring):
            "SpringParameters(response: \(format(spring.response)), dampingFraction: \(format(spring.dampingFraction)))"
        }
    }

    /// A number with at most four fraction digits and no trailing zeros.
    public static func format(_ number: Double) -> String {
        let rounded = (number * 10_000).rounded() / 10_000
        if rounded == rounded.rounded(), abs(rounded) < 1e12 { return String(Int64(rounded)) }
        var text = String(format: "%.4f", rounded)
        while text.hasSuffix("0") { text.removeLast() }
        return text
    }
}

/// Search in Debug Settings: every word of the query must appear in the
/// label, key, help, section title or code name (case and diacritics
/// ignored). Results keep section order, label matches first.
public nonisolated enum TunableSearch {
    public static func matches(_ descriptor: TunableDescriptor, query: String) -> Bool {
        let words = tokens(query)
        guard !words.isEmpty else { return true }
        let haystack = fold([descriptor.label, descriptor.key, descriptor.help, descriptor.section.title,
                             descriptor.codeName ?? ""].joined(separator: " "))
        return words.allSatisfy { haystack.contains($0) }
    }

    /// The descriptors that match `query`, sorted by section, then label
    /// matches before key/help matches, then label.
    public static func filter(_ descriptors: [TunableDescriptor], query: String) -> [TunableDescriptor] {
        let words = tokens(query)
        return descriptors
            .filter { matches($0, query: query) }
            .sorted { lhs, rhs in
                let left = (lhs.section.order, labelRank(lhs, words), lhs.label)
                let right = (rhs.section.order, labelRank(rhs, words), rhs.label)
                return left < right
            }
    }

    private static func labelRank(_ descriptor: TunableDescriptor, _ words: [String]) -> Int {
        guard !words.isEmpty else { return 0 }
        let label = fold(descriptor.label)
        return words.allSatisfy { label.contains($0) } ? 0 : 1
    }

    private static func tokens(_ query: String) -> [String] {
        fold(query).split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
