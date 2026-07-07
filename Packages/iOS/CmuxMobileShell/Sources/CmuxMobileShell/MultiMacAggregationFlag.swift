import Foundation

enum MultiMacAggregationFlag {
    static func isEnabled(environment: [String: String], defaults: UserDefaults) -> Bool {
        if let raw = environment["CMUX_MULTI_MAC_AGGREGATION"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            return ["1", "true", "yes", "on"].contains(raw.lowercased())
        }
        if defaults.object(forKey: "multiMacAggregation") != nil {
            return defaults.bool(forKey: "multiMacAggregation")
        }
        return true
    }
}
