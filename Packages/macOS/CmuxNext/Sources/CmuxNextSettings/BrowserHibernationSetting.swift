/// `browser.hibernation` and its companions in cmux.json: when hidden
/// browser pages hibernate (their engine page is closed to free memory and
/// recreated with its history when selected).
///
/// ```jsonc
/// "browser": {
///   "hibernation": "moderate",        // "off" | "moderate" | "aggressive" | minutes (number)
///   "hibernationExclusions": ["mail.google.com", "*.example.com"],
///   "hibernatePinnedTabs": false,
///   "freezeHiddenTabs": 30,          // "off" | seconds (number)
///   "keepNeighborTabsAwake": 1       // 0...3 tabs on each side of the shown tab
/// }
/// ```
///
/// "off" disables it completely, including under memory pressure.
///
/// A discard reloads the page when it wakes: it loses its scroll, form state and script state,
/// and a page behind a login or a sudo prompt can come back signed out ("why does cmux-next's
/// browser keep refreshing and reloading?", Leo 2026-10-26). So hidden pages only freeze by
/// default; they are discarded on their own (after the timeout or under memory pressure) only
/// once cmux.json sets `browser.hibernation` (`discardsAutomatically`). The person's Hibernate
/// Tab discards whatever the setting.
///
/// `freezeHiddenTabs` is separate: a hidden Chromium page freezes (its timers,
/// tasks and rendering stop; it keeps its memory and state) after that many
/// seconds, and thaws when shown. It saves power, not memory.
/// `keepNeighborTabsAwake` keeps that many tabs on each side of each pane's
/// shown tab (wrapping, as Ctrl-Tab does) unfrozen and loaded, so a switch to
/// a nearby tab is instant; memory pressure and Low Power Mode reduce it to 0.
public nonisolated struct BrowserHibernationSetting: Sendable, Hashable {
    public enum Mode: Sendable, Hashable {
        case off
        /// After 30 minutes hidden (later for a tab the person keeps coming back to); earlier
        /// under memory pressure.
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
    /// Seconds hidden before a page freezes; nil never freezes. Pinned
    /// tabs (unless `includesPinnedTabs`) and exclusions stay awake.
    public var freezeSeconds: Double?

    /// Seconds hidden before a page freezes by default: long enough for a
    /// quick switch back, short against the ~1 Hz wakeups of each hidden renderer.
    public static let defaultFreezeSeconds: Double = 30
    /// Tabs on each side of each pane's shown tab that stay awake (0 turns it off).
    public var neighborRadius: Int
    /// One tab on each side by default: Ctrl-Tab, Cmd-Shift-[ ] and the next click are warm.
    public static let defaultNeighborRadius = 1
    /// Hidden pages are discarded on their own (the timeout, memory pressure). False unless
    /// cmux.json sets `browser.hibernation`: a discarded page reloads when it wakes, so by
    /// default hidden pages only freeze, which keeps their state.
    public var discardsAutomatically: Bool
    /// The values `browser.keepNeighborTabsAwake` accepts.
    public static let neighborRadiusRange = 0...3

    public init(mode: Mode, exclusions: [String] = [], includesPinnedTabs: Bool = false,
                freezeSeconds: Double? = BrowserHibernationSetting.defaultFreezeSeconds,
                neighborRadius: Int = BrowserHibernationSetting.defaultNeighborRadius,
                discardsAutomatically: Bool = true) {
        self.mode = mode
        self.discardsAutomatically = discardsAutomatically
        self.exclusions = exclusions
        self.includesPinnedTabs = includesPinnedTabs
        self.freezeSeconds = freezeSeconds
        self.neighborRadius = neighborRadius
    }

    public static let configPath = ["browser", "hibernation"]
    /// No `browser.hibernation` in cmux.json: hidden pages freeze and are never discarded on their own.
    public static let fallback = BrowserHibernationSetting(mode: .moderate, discardsAutomatically: false)
    public static let neighborRadiusPath = ["browser", "keepNeighborTabsAwake"]
    public static let exclusionsPath = ["browser", "hibernationExclusions"]

    public var isEnabled: Bool { mode != .off }

    /// Minutes hidden before a page hibernates; nil when off.
    public var hiddenMinutes: Double? {
        switch mode {
        case .off: nil
        case .moderate: 30
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

    /// The setting with `host` added to the exclusions ("Never Hibernate This Site"), lowercased;
    /// unchanged when an exclusion already matches it or there is no host.
    public func addingExclusion(host: String?) -> BrowserHibernationSetting {
        guard let host = host?.lowercased(), !host.isEmpty, !excludes(host: host) else { return self }
        var setting = self
        setting.exclusions.append(host)
        return setting
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
                setting.discardsAutomatically = true
            } else if let text = value.stringValue, let mode = [("off", Mode.off), ("moderate", .moderate), ("aggressive", .aggressive)]
                .first(where: { $0.0 == text })?.1 {
                setting.mode = mode
                setting.discardsAutomatically = true
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
        if let value = browser["freezeHiddenTabs"] {
            if let number = value.doubleValue, number > 0 {
                setting.freezeSeconds = number
            } else if value.stringValue == "off" {
                setting.freezeSeconds = nil
            } else {
                diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: "browser.freezeHiddenTabs",
                                                      message: "expected \"off\" or a number of seconds > 0"))
            }
        }
        if let value = browser["keepNeighborTabsAwake"] {
            if let number = value.doubleValue, number == number.rounded(), neighborRadiusRange.contains(Int(exactly: number) ?? -1) {
                setting.neighborRadius = Int(exactly: number) ?? defaultNeighborRadius
            } else {
                diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: "browser.keepNeighborTabsAwake",
                                                      message: "expected a whole number from 0 to 3"))
            }
        }
        return (setting, diagnostics)
    }
}
