public import Foundation

/// lint:allow namespace-type: moved unchanged from the app target, where it was an internal static namespace; reshaping it is a separate change from this package move.
public enum BrowserHiddenWebViewDiscardPolicy {
    public struct ResolvedPolicy: Equatable {
        public let isEnabled: Bool
        public let hiddenDelay: TimeInterval
    }

    public static let enabledKey = "browserHiddenWebViewDiscardEnabled"
    public static let hiddenDelayKey = "browserHiddenWebViewDiscardDelaySeconds"
    public static let defaultEnabled = true
    public static let defaultHiddenDelay: TimeInterval = 300
    static let minimumHiddenDelay: TimeInterval = 0
    public static let maximumHiddenDelay: TimeInterval = 3600

    public static var isEnabled: Bool {
        isEnabled(defaults: .standard)
    }

    public static var hiddenDelay: TimeInterval {
        hiddenDelay(defaults: .standard)
    }

    public static func resolved(defaults: UserDefaults = .standard) -> ResolvedPolicy {
        ResolvedPolicy(
            isEnabled: isEnabled(defaults: defaults),
            hiddenDelay: hiddenDelay(defaults: defaults)
        )
    }

    public static func isEnabled(defaults: UserDefaults) -> Bool {
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

    public static func clampedHiddenDelay(_ value: TimeInterval) -> TimeInterval {
        guard value.isFinite else { return defaultHiddenDelay }
        return min(max(value, minimumHiddenDelay), maximumHiddenDelay)
    }

    public static func resolvedHiddenDelay(_ value: TimeInterval) -> TimeInterval? {
        guard value.isFinite, value >= minimumHiddenDelay, value <= maximumHiddenDelay else { return nil }
        return clampedHiddenDelay(value)
    }

    public static func hiddenDelay(defaults: UserDefaults) -> TimeInterval {
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
