public import Foundation

/// Resolves whether hidden browser web views should be discarded and how long a
/// view may stay hidden before discard, from the environment and `UserDefaults`.
///
/// This replaces the app target's caseless `BrowserHiddenWebViewDiscardPolicy`
/// namespace enum (all-`static` env + `UserDefaults` accessors) with a value type
/// that takes its `UserDefaults` and `ProcessInfo` through the initializer,
/// mirroring ``BrowserToolbarAccessorySpacingDebugRepository`` and
/// ``BrowserDefaultsNormalizer``. The `static let` keys/defaults/bounds and the
/// pure clamps (``clampedHiddenDelay(_:)``, ``resolvedHiddenDelay(_:)``) stay
/// byte-identical to the app target, so the persisted value and the running
/// browser agree and the app's settings JSON-path mapping keeps resolving the
/// same keys.
///
/// The env-var probe goes through the injected ``processInfo`` and the stored
/// reads through the injected ``defaults``; the app owns picking
/// `ProcessInfo.processInfo` / `UserDefaults.standard` at the composition point.
public struct BrowserHiddenWebViewDiscardPolicy {
    /// The resolved policy: whether discard is enabled and the hidden delay in seconds.
    public struct ResolvedPolicy: Equatable, Sendable {
        /// Whether hidden web views should be discarded.
        public let isEnabled: Bool
        /// How long a web view may stay hidden before it is eligible for discard.
        public let hiddenDelay: TimeInterval

        /// Creates a resolved policy.
        public init(isEnabled: Bool, hiddenDelay: TimeInterval) {
            self.isEnabled = isEnabled
            self.hiddenDelay = hiddenDelay
        }
    }

    /// The `UserDefaults` key storing whether hidden-web-view discard is enabled.
    public static let enabledKey = "browserHiddenWebViewDiscardEnabled"

    /// The `UserDefaults` key storing the hidden-web-view discard delay in seconds.
    public static let hiddenDelayKey = "browserHiddenWebViewDiscardDelaySeconds"

    /// Whether discard is enabled when no value is stored and no env override applies.
    public static let defaultEnabled = true

    /// The shipped default hidden delay in seconds when no value is stored or the
    /// stored value is out of range.
    public static let defaultHiddenDelay: TimeInterval = 300

    /// The minimum accepted hidden delay in seconds.
    public static let minimumHiddenDelay: TimeInterval = 0

    /// The maximum accepted hidden delay in seconds.
    public static let maximumHiddenDelay: TimeInterval = 3600

    private let defaults: UserDefaults
    private let processInfo: ProcessInfo

    /// Creates a policy backed by the given `UserDefaults` and `ProcessInfo`.
    public init(defaults: UserDefaults = .standard, processInfo: ProcessInfo = .processInfo) {
        self.defaults = defaults
        self.processInfo = processInfo
    }

    /// Whether hidden web views should currently be discarded, honoring the
    /// `CMUX_BROWSER_HIDDEN_WEBVIEW_DISCARD_ENABLED` env override before the
    /// stored value and the shipped default.
    public var isEnabled: Bool {
        let value = processInfo.environment["CMUX_BROWSER_HIDDEN_WEBVIEW_DISCARD_ENABLED"]?
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
        if defaults.object(forKey: Self.enabledKey) == nil {
            return Self.defaultEnabled
        }
        return defaults.bool(forKey: Self.enabledKey)
    }

    /// The currently resolved hidden delay in seconds, honoring the
    /// `CMUX_BROWSER_HIDDEN_WEBVIEW_DISCARD_DELAY_SECONDS` env override before the
    /// stored value and the shipped default.
    public var hiddenDelay: TimeInterval {
        let rawValue = processInfo.environment["CMUX_BROWSER_HIDDEN_WEBVIEW_DISCARD_DELAY_SECONDS"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let rawValue, let value = TimeInterval(rawValue), let resolvedValue = Self.resolvedHiddenDelay(value) else {
            let storedValue = defaults.double(forKey: Self.hiddenDelayKey)
            guard defaults.object(forKey: Self.hiddenDelayKey) != nil,
                  let resolvedStoredValue = Self.resolvedHiddenDelay(storedValue) else {
                return Self.defaultHiddenDelay
            }
            return resolvedStoredValue
        }
        return resolvedValue
    }

    /// The full resolved policy (``isEnabled`` plus ``hiddenDelay``).
    public func resolved() -> ResolvedPolicy {
        ResolvedPolicy(isEnabled: isEnabled, hiddenDelay: hiddenDelay)
    }

    /// Clamps a delay to `[minimumHiddenDelay, maximumHiddenDelay]`, falling back
    /// to ``defaultHiddenDelay`` for non-finite input.
    public static func clampedHiddenDelay(_ value: TimeInterval) -> TimeInterval {
        guard value.isFinite else { return defaultHiddenDelay }
        return min(max(value, minimumHiddenDelay), maximumHiddenDelay)
    }

    /// Returns the clamped delay when `value` is finite and already within range,
    /// or `nil` when it is non-finite or out of range.
    public static func resolvedHiddenDelay(_ value: TimeInterval) -> TimeInterval? {
        guard value.isFinite, value >= minimumHiddenDelay, value <= maximumHiddenDelay else { return nil }
        return clampedHiddenDelay(value)
    }
}
