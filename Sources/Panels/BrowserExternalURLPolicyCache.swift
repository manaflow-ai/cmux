import CmuxSettings
import Foundation

/// Caches the compiled external-URL policy for one navigation owner.
@MainActor
final class BrowserExternalURLPolicyCache {
    private let defaults: UserDefaults
    private var cachedSignature: String?
    private var cachedPolicy: BrowserExternalURLPolicy?
    private let maximumSignatureLength = 65_536
    private let maximumSignatureValues = 256

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// Returns a compiled policy, rebuilding it only when the stored rule value changes.
    func currentPolicy() -> BrowserExternalURLPolicy {
        let signature = signature(for: defaults.object(forKey: BrowserExternalURLPolicy.userDefaultsKey))
        if let cachedPolicy, cachedSignature == signature {
            return cachedPolicy
        }
        let policy = BrowserExternalURLPolicy(defaults: defaults)
        cachedSignature = signature
        cachedPolicy = policy
        return policy
    }

    private func signature(for rawValue: Any?) -> String {
        if let value = rawValue as? String {
            return "string:\(String(value.prefix(maximumSignatureLength)))"
        }
        if let values = rawValue as? [String] {
            return "array:\(boundedSignature(values))"
        }
        if let values = rawValue as? NSArray {
            let strings = values.compactMap { $0 as? String }
            guard strings.count == values.count else { return "unsupported-array:\(values.count)" }
            return "array:\(boundedSignature(strings))"
        }
        return rawValue == nil ? "absent" : "unsupported"
    }

    private func boundedSignature(_ values: [String]) -> String {
        var signature = ""
        var remaining = maximumSignatureLength
        for value in values.prefix(maximumSignatureValues) {
            guard remaining > 0 else { break }
            let prefix = String(value.prefix(remaining))
            signature += "\(prefix.count):\(prefix)|"
            remaining -= prefix.count
        }
        return signature
    }
}
