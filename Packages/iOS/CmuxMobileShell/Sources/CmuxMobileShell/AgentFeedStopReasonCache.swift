import Foundation

/// Reuses completion comparisons across full snapshots, retaining only reasons
/// still present in the feed. A changed reason gets its own normalized value.
struct AgentFeedStopReasonCache {
    private struct Reason {
        let text: String
        let characterCount: Int
    }

    private var reasons: [String: Reason] = [:]
    private let normalize: (String) -> String

    init(normalize: @escaping (String) -> String = AgentFeedStopReasonCache.normalize) {
        self.normalize = normalize
    }

    mutating func retain(reasons retained: Set<String>) {
        reasons = reasons.filter { retained.contains($0.key) }
    }

    mutating func matches(_ lhs: String, _ rhs: String) -> Bool {
        let a = reason(lhs)
        let b = reason(rhs)
        guard !a.text.isEmpty, !b.text.isEmpty else { return false }
        if a.text == b.text { return true }
        let (shorter, longer) = a.characterCount <= b.characterCount ? (a, b) : (b, a)
        // Distinct complete responses never collapse, even when one is a
        // prefix of the other. Only an explicit truncated preview may match.
        guard shorter.text.hasSuffix("…") else { return false }
        return longer.text.hasPrefix(String(shorter.text.dropLast()))
    }

    private mutating func reason(_ source: String) -> Reason {
        if let cached = reasons[source] { return cached }
        let text = normalize(source)
        let result = Reason(text: text, characterCount: text.count)
        reasons[source] = result
        return result
    }

    private static func normalize(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
