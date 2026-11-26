public import CmuxSettings
public import Foundation

/// lint:allow namespace-type: moved unchanged from the app target, where it was an internal static namespace; reshaping it is a separate change from this package move.
public enum BrowserHiddenWebViewDiscardPolicy {
    public struct ResolvedPolicy: Equatable {
        public let isEnabled: Bool
        public let hiddenDelay: TimeInterval
        public let mode: BrowserHiddenWebViewDiscardMode
        public let memoryBudgetMB: Int
        public let autoRestoresUnloadedPages: Bool
    }

    public static let enabledKey = "browserHiddenWebViewDiscardEnabled"
    public static let hiddenDelayKey = "browserHiddenWebViewDiscardDelaySeconds"
    public static let defaultEnabled = true
    public static let defaultHiddenDelay: TimeInterval = 300
    static let minimumHiddenDelay: TimeInterval = 0
    public static let maximumHiddenDelay: TimeInterval = 3600
    public static let modeKey = "browserHiddenWebViewDiscardMode"
    public static let defaultMode: BrowserHiddenWebViewDiscardMode = .memoryBudget
    public static let memoryBudgetKey = "browserHiddenWebViewMemoryBudgetMB"
    public static let defaultMemoryBudgetMB = 2048
    public static let minimumMemoryBudgetMB = 256
    public static let maximumMemoryBudgetMB = 65536
    public static let autoRestoreKey = "browserAutoRestoreUnloadedPages"
    public static let defaultAutoRestore = true

    public static var isEnabled: Bool {
        isEnabled(defaults: .standard)
    }

    public static var hiddenDelay: TimeInterval {
        hiddenDelay(defaults: .standard)
    }

    public static func resolved(defaults: UserDefaults = .standard) -> ResolvedPolicy {
        ResolvedPolicy(
            isEnabled: isEnabled(defaults: defaults),
            hiddenDelay: hiddenDelay(defaults: defaults),
            mode: mode(defaults: defaults),
            memoryBudgetMB: memoryBudgetMB(defaults: defaults),
            autoRestoresUnloadedPages: autoRestoresUnloadedPages(defaults: defaults)
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

    /// The discard mode, from `CMUX_BROWSER_HIDDEN_WEBVIEW_DISCARD_MODE` or
    /// the stored setting. Unknown values fall back to the memory budget.
    public static func mode(defaults: UserDefaults) -> BrowserHiddenWebViewDiscardMode {
        let rawValue = ProcessInfo.processInfo.environment["CMUX_BROWSER_HIDDEN_WEBVIEW_DISCARD_MODE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if let rawValue, let mode = BrowserHiddenWebViewDiscardMode(rawValue: rawValue) {
            return mode
        }
        return defaults.string(forKey: modeKey).flatMap(BrowserHiddenWebViewDiscardMode.init(rawValue:))
            ?? defaultMode
    }

    /// Returns `value` when it is a supported budget, in megabytes.
    public static func resolvedMemoryBudgetMB(_ value: Int) -> Int? {
        (minimumMemoryBudgetMB...maximumMemoryBudgetMB).contains(value) ? value : nil
    }

    /// The hidden web content memory budget in megabytes, from
    /// `CMUX_BROWSER_HIDDEN_WEBVIEW_MEMORY_BUDGET_MB` or the stored setting.
    public static func memoryBudgetMB(defaults: UserDefaults) -> Int {
        let rawValue = ProcessInfo.processInfo.environment["CMUX_BROWSER_HIDDEN_WEBVIEW_MEMORY_BUDGET_MB"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let rawValue, let value = Int(rawValue), let resolvedValue = resolvedMemoryBudgetMB(value) {
            return resolvedValue
        }
        guard defaults.object(forKey: memoryBudgetKey) != nil,
              let storedValue = resolvedMemoryBudgetMB(defaults.integer(forKey: memoryBudgetKey)) else {
            return defaultMemoryBudgetMB
        }
        return storedValue
    }

    /// Whether an unloaded page restores as soon as its pane is shown. When
    /// off, the pane shows a placeholder until the user restores it
    /// (https://github.com/manaflow-ai/cmux/issues/9561).
    public static func autoRestoresUnloadedPages(defaults: UserDefaults) -> Bool {
        guard defaults.object(forKey: autoRestoreKey) != nil else { return defaultAutoRestore }
        return defaults.bool(forKey: autoRestoreKey)
    }
}
