import CmuxSettings
import Foundation

/// Caches the compiled external-URL policy for one navigation owner.
@MainActor
final class BrowserExternalURLPolicyCache {
    private let defaults: UserDefaults
    private let maximumPatternCount = 256
    private let maximumInputValueCount = 512
    private let maximumTotalPatternLength = 65_536
    private var cachedSignature: String?
    private var cachedRawObject: AnyObject?
    private var cachedPolicy: BrowserExternalURLPolicy?

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// Returns a compiled policy, rebuilding it only when its effective rules change.
    func currentPolicy() -> BrowserExternalURLPolicy {
        let rawValue = defaults.object(forKey: BrowserExternalURLPolicy.userDefaultsKey)
        let rawObject = rawValue as AnyObject?
        // UserDefaults returns immutable property-list snapshots. Reusing the
        // same snapshot avoids re-normalizing on every link; the normalized
        // signature below remains the fallback when a bridge returns a copy.
        if let cachedPolicy,
           ((cachedRawObject == nil && rawObject == nil) ||
               (cachedRawObject != nil && cachedRawObject === rawObject)) {
            return cachedPolicy
        }

        let signature = signature(for: rawValue)
        if let cachedPolicy, cachedSignature == signature {
            cachedRawObject = rawObject
            return cachedPolicy
        }
        let policy = BrowserExternalURLPolicy(defaults: defaults)
        cachedSignature = signature
        cachedRawObject = rawObject
        cachedPolicy = policy
        return policy
    }

    private func signature(for rawValue: Any?) -> String {
        let values: [String]
        if let value = rawValue as? String {
            values = [value]
        } else if let valuesArray = rawValue as? [String] {
            values = Array(valuesArray.prefix(maximumInputValueCount))
        } else if let valuesArray = rawValue as? NSArray {
            let limitedValues = Array(valuesArray.prefix(maximumInputValueCount))
            let strings = limitedValues.compactMap { $0 as? String }
            guard strings.count == limitedValues.count else {
                return "unsupported-array:\(limitedValues.count)"
            }
            values = strings
        } else {
            return rawValue == nil ? "absent" : "unsupported"
        }
        return "rules:\(normalizedSignature(from: values))"
    }

    /// Mirrors the policy matcher’s normalization limits without compiling regexes.
    private func normalizedSignature(from values: [String]) -> String {
        var seen = Set<String>()
        var signature = ""
        var totalLength = 0
        var patternCount = 0

        for value in values.prefix(maximumInputValueCount) {
            guard totalLength < maximumTotalPatternLength else { break }
            let boundedValue = String(value.prefix(maximumTotalPatternLength))
            for token in boundedValue.components(separatedBy: .newlines) {
                let normalized = token.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !normalized.isEmpty, !normalized.hasPrefix("#") else { continue }
                guard seen.insert(normalized).inserted else { continue }
                guard patternCount < maximumPatternCount,
                      totalLength + normalized.count <= maximumTotalPatternLength else {
                    return signature
                }
                signature += "\(normalized.count):\(normalized)|"
                patternCount += 1
                totalLength += normalized.count
            }
        }
        return signature
    }
}
