import Foundation

enum BrowserHiddenWebViewDiscardPolicy {
    struct ResolvedPolicy: Equatable {
        let isEnabled: Bool
        let hiddenDelay: TimeInterval
    }

    static let enabledKey = "browserHiddenWebViewDiscardEnabled"
    static let hiddenDelayKey = "browserHiddenWebViewDiscardDelaySeconds"
    static let defaultEnabled = true
    static let defaultHiddenDelay: TimeInterval = 300
    static let minimumHiddenDelay: TimeInterval = 0
    static let maximumHiddenDelay: TimeInterval = 3600

    static var isEnabled: Bool {
        isEnabled(defaults: .standard)
    }

    static var hiddenDelay: TimeInterval {
        hiddenDelay(defaults: .standard)
    }

    static func resolved(defaults: UserDefaults = .standard) -> ResolvedPolicy {
        ResolvedPolicy(
            isEnabled: isEnabled(defaults: defaults),
            hiddenDelay: hiddenDelay(defaults: defaults)
        )
    }

    static func isEnabled(defaults: UserDefaults) -> Bool {
        let value = ProcessInfo.processInfo.environment["CMUX_BROWSER_HIDDEN_WEBVIEW_DISCARD_ENABLED"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if let value {
            switch value {
            case "1", "true", "yes", "on":
                return true
            case "0", "false", "no", "off":
                return false
            default:
                break
            }
        }
        if defaults.object(forKey: enabledKey) == nil {
            return defaultEnabled
        }
        return defaults.bool(forKey: enabledKey)
    }

    static func clampedHiddenDelay(_ value: TimeInterval) -> TimeInterval {
        guard value.isFinite else { return defaultHiddenDelay }
        return min(max(value, minimumHiddenDelay), maximumHiddenDelay)
    }

    static func resolvedHiddenDelay(_ value: TimeInterval) -> TimeInterval? {
        guard value.isFinite, value >= minimumHiddenDelay, value <= maximumHiddenDelay else { return nil }
        return clampedHiddenDelay(value)
    }

    static func hiddenDelay(defaults: UserDefaults) -> TimeInterval {
        let rawValue = ProcessInfo.processInfo.environment["CMUX_BROWSER_HIDDEN_WEBVIEW_DISCARD_DELAY_SECONDS"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let rawValue, let value = TimeInterval(rawValue), let resolvedValue = resolvedHiddenDelay(value) else {
            let storedValue = defaults.double(forKey: hiddenDelayKey)
            guard defaults.object(forKey: hiddenDelayKey) != nil,
                  let resolvedStoredValue = resolvedHiddenDelay(storedValue) else {
                return defaultHiddenDelay
            }
            return resolvedStoredValue
        }
        return resolvedValue
    }
}
