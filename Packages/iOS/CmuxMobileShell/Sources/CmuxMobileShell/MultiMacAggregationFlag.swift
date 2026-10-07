import Foundation

/// Resolves whether the multi-Mac aggregated workspace list is enabled: env
/// override, then UserDefaults, then enabled by default. Env/defaults are kill
/// switches for rollout control.
struct MultiMacAggregationFlag {
    private let environment: [String: String]
    private let defaults: UserDefaults

    init(environment: [String: String], defaults: UserDefaults) {
        self.environment = environment
        self.defaults = defaults
    }

    var isEnabled: Bool {
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
