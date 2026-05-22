import Foundation

nonisolated enum BrowserHiddenWebViewDiscardPolicy {
    struct ResolvedPolicy: Equatable {
        let isEnabled: Bool
        let hiddenDelay: TimeInterval
        let maxLiveHiddenCount: Int
    }

    static let enabledKey = "browserHiddenWebViewDiscardEnabled"
    static let hiddenDelayKey = "browserHiddenWebViewDiscardDelaySeconds"
    static let maxLiveHiddenCountKey = "browserHiddenWebViewMaxLiveHiddenCount"
    static let maxLiveHiddenCountEnvironmentKey = "CMUX_BROWSER_HIDDEN_WEBVIEW_MAX_LIVE_HIDDEN_COUNT"
    static let legacyMaxLiveHiddenCountEnvironmentKey = "CMUX_BROWSER_HIDDEN_WEBVIEW_MAX_LIVE_COUNT"
    static let defaultEnabled = true
    static let defaultHiddenDelay: TimeInterval = 1800
    static let defaultMaxLiveHiddenCount = 5
    static let minimumHiddenDelay: TimeInterval = 0
    static let maximumHiddenDelay: TimeInterval = 3600
    static let minimumMaxLiveHiddenCount = 0
    static let maximumMaxLiveHiddenCount = 100

    static var isEnabled: Bool {
        isEnabled(defaults: .standard)
    }

    static var hiddenDelay: TimeInterval {
        hiddenDelay(defaults: .standard)
    }

    static var maxLiveHiddenCount: Int {
        maxLiveHiddenCount(defaults: .standard)
    }

    static func resolved(defaults: UserDefaults = .standard) -> ResolvedPolicy {
        ResolvedPolicy(
            isEnabled: isEnabled(defaults: defaults),
            hiddenDelay: hiddenDelay(defaults: defaults),
            maxLiveHiddenCount: maxLiveHiddenCount(defaults: defaults)
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

    static func clampedMaxLiveHiddenCount(_ value: Int) -> Int {
        min(max(value, minimumMaxLiveHiddenCount), maximumMaxLiveHiddenCount)
    }

    static func resolvedMaxLiveHiddenCount(_ value: Int) -> Int? {
        guard value >= minimumMaxLiveHiddenCount, value <= maximumMaxLiveHiddenCount else { return nil }
        return clampedMaxLiveHiddenCount(value)
    }

    static func maxLiveHiddenCount(defaults: UserDefaults) -> Int {
        let environment = ProcessInfo.processInfo.environment
        let rawValue = (environment[maxLiveHiddenCountEnvironmentKey] ?? environment[legacyMaxLiveHiddenCountEnvironmentKey])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let rawValue, let value = Int(rawValue), let resolvedValue = resolvedMaxLiveHiddenCount(value) {
            return resolvedValue
        }

        guard defaults.object(forKey: maxLiveHiddenCountKey) != nil else {
            return defaultMaxLiveHiddenCount
        }
        let storedValue = defaults.integer(forKey: maxLiveHiddenCountKey)
        return resolvedMaxLiveHiddenCount(storedValue) ?? defaultMaxLiveHiddenCount
    }
}
