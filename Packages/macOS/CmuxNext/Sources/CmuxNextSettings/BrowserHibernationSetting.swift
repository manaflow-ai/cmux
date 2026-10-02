/// `browser.hibernation` and its companions in cmux.json: when hidden
/// browser pages hibernate (their engine page is closed to free memory and
/// recreated with its history when selected; Chrome's Memory Saver).
///
/// ```jsonc
/// "browser": {
///   "hibernation": "moderate",        // "off" | "moderate" | "aggressive" | minutes (number)
///   "hibernationExclusions": ["mail.google.com", "*.example.com"],
///   "hibernatePinnedTabs": false
/// }
/// ```
///
/// "off" disables it completely, including under memory pressure.
public nonisolated struct BrowserHibernationSetting: Sendable, Hashable {
    public enum Mode: Sendable, Hashable {
        case off
        /// After 60 minutes hidden; earlier under memory pressure.
        case moderate
        /// After 10 minutes hidden; every eligible hidden page under pressure.
        case aggressive
        /// After this many minutes hidden.
        case minutes(Double)
    }

    public var mode: Mode
    /// Hosts that never hibernate: `example.com` (and its subdomains) or
    /// `*.example.com` (subdomains only).
    public var exclusions: [String]
    /// Pinned tabs hibernate too (default false: pinned tabs stay loaded).
    public var includesPinnedTabs: Bool

    public init(mode: Mode, exclusions: [String] = [], includesPinnedTabs: Bool = false) {
        self.mode = mode
        self.exclusions = exclusions
        self.includesPinnedTabs = includesPinnedTabs
    }

    public static let configPath = ["browser", "hibernation"]
    public static let fallback = BrowserHibernationSetting(mode: .moderate)

    public var isEnabled: Bool { mode != .off }

    /// Minutes hidden before a page hibernates; nil when off.
    public var hiddenMinutes: Double? {
        switch mode {
        case .off: nil
        case .moderate: 60
        case .aggressive: 10
        case .minutes(let minutes): minutes
        }
    }

    /// The value written to `browser.hibernation`.
    public var configValue: JSONValue {
        switch mode {
        case .off: .string("off")
        case .moderate: .string("moderate")
        case .aggressive: .string("aggressive")
        case .minutes(let minutes): .number(minutes)
        }
    }

    /// True when `host` matches an exclusion.
    public func excludes(host: String?) -> Bool {
        guard let host = host?.lowercased(), !host.isEmpty else { return false }
        return exclusions.contains { pattern in
            let pattern = pattern.lowercased()
            if pattern.hasPrefix("*.") { return host.hasSuffix(String(pattern.dropFirst(1))) }
            return host == pattern || host.hasSuffix("." + pattern)
        }
    }

    /// Parses the `browser` section. Missing keys are defaults with no
    /// diagnostic; bad values are defaults plus a diagnostic.
    static func parse(_ root: JSONValue) -> (BrowserHibernationSetting, [SettingsDiagnostic]) {
        var setting = fallback
        var diagnostics: [SettingsDiagnostic] = []
        guard case .object(let browser)? = root["browser"] else { return (setting, diagnostics) }
        if let value = browser["hibernation"] {
            if let number = value.doubleValue, number > 0 {
                setting.mode = .minutes(number)
            } else if let text = value.stringValue, let mode = [("off", Mode.off), ("moderate", .moderate), ("aggressive", .aggressive)]
                .first(where: { $0.0 == text })?.1 {
                setting.mode = mode
            } else {
                diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: "browser.hibernation",
                                                      message: "expected \"off\", \"moderate\", \"aggressive\" or a number of minutes > 0"))
            }
        }
        if let value = browser["hibernationExclusions"] {
            if case .array(let items) = value, items.allSatisfy({ $0.stringValue != nil }) {
                setting.exclusions = items.compactMap(\.stringValue).filter { !$0.isEmpty }
            } else {
                diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: "browser.hibernationExclusions", message: "expected an array of host names"))
            }
        }
        if let value = browser["hibernatePinnedTabs"] {
            if let flag = value.boolValue {
                setting.includesPinnedTabs = flag
            } else {
                diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: "browser.hibernatePinnedTabs", message: "expected true or false"))
            }
        }
        return (setting, diagnostics)
    }
}
