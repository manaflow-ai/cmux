import Darwin
import Foundation

enum WorkspaceTitlebarSettings {
    static let showTitlebarKey = "workspaceTitlebarVisible"
    static let defaultShowTitlebar = true

    static func isVisible(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: showTitlebarKey) == nil {
            return defaultShowTitlebar
        }
        return defaults.bool(forKey: showTitlebarKey)
    }
}
enum WorkspacePresentationModeSettings {
    static let modeKey = "workspacePresentationMode"

    enum Mode: String {
        case standard
        case minimal
    }

    static let defaultMode: Mode = .standard

    static func mode(for rawValue: String?) -> Mode {
        Mode(rawValue: rawValue ?? "") ?? defaultMode
    }

    static func mode(defaults: UserDefaults = .standard) -> Mode {
        mode(for: defaults.string(forKey: modeKey))
    }

    static func isMinimal(defaults: UserDefaults = .standard) -> Bool {
        mode(defaults: defaults) == .minimal
    }
}

enum WorkspaceButtonFadeSettings {
    static let modeKey = "workspaceButtonsFadeMode"
    static let legacyTitlebarControlsVisibilityModeKey = "titlebarControlsVisibilityMode"
    static let legacyPaneTabBarControlsVisibilityModeKey = "paneTabBarControlsVisibilityMode"

    enum Mode: String {
        case enabled
        case disabled
    }

    static let defaultMode: Mode = .disabled

    static func mode(for rawValue: String?) -> Mode {
        Mode(rawValue: rawValue ?? "") ?? defaultMode
    }

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        mode(for: defaults.string(forKey: modeKey)) == .enabled
    }

    static func initializeStoredModeIfNeeded(defaults: UserDefaults = .standard) {
        guard defaults.string(forKey: modeKey) == nil else { return }

        if let migratedMode = migratedLegacyMode(defaults: defaults) {
            defaults.set(migratedMode.rawValue, forKey: modeKey)
            return
        }

        let initialMode: Mode = WorkspaceTitlebarSettings.isVisible(defaults: defaults) ? .disabled : .enabled
        defaults.set(initialMode.rawValue, forKey: modeKey)
    }

    private static func migratedLegacyMode(defaults: UserDefaults) -> Mode? {
        let legacyValues = [
            defaults.string(forKey: legacyTitlebarControlsVisibilityModeKey),
            defaults.string(forKey: legacyPaneTabBarControlsVisibilityModeKey),
        ]

        if legacyValues.contains(where: { $0 == "onHover" || $0 == "hover" || $0 == "enabled" }) {
            return .enabled
        }
        if legacyValues.contains(where: { $0 == "always" || $0 == "disabled" }) {
            return .disabled
        }
        return nil
    }
}

enum PaneFirstClickFocusSettings {
    static let enabledKey = "paneFirstClickFocus.enabled"
    static let defaultEnabled = false

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? defaultEnabled
    }
}

enum TerminalScrollBarSettings {
    static let showScrollBarKey = "terminal.showScrollBar"
    static let defaultShowScrollBar = true
    static let didChangeNotification = Notification.Name("cmux.terminalScrollBarSettingsDidChange")

    static func isVisible(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: showScrollBarKey) == nil {
            return defaultShowScrollBar
        }
        return defaults.bool(forKey: showScrollBarKey)
    }

    static func notifyDidChange(notificationCenter: NotificationCenter = .default) {
        notificationCenter.post(name: didChangeNotification, object: nil)
    }
}

enum TerminalTextBoxInputSettings {
    static let showOnNewTerminalsKey = "terminal.showTextBoxOnNewTerminals"
    static let focusOnNewTerminalsKey = "terminal.focusTextBoxOnNewTerminals"
    static let defaultShowOnNewTerminals = false
    static let defaultFocusOnNewTerminals = false
    static let maxLinesKey = "terminal.textBoxMaxLines"
    static let defaultMaxLines = 10
    static let minimumMaxLines = 1
    static let maximumMaxLines = 20

    static func showOnNewTerminals(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: showOnNewTerminalsKey) == nil {
            return defaultShowOnNewTerminals
        }
        return defaults.bool(forKey: showOnNewTerminalsKey)
    }

    static func focusOnNewTerminals(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: focusOnNewTerminalsKey) == nil {
            return defaultFocusOnNewTerminals
        }
        return defaults.bool(forKey: focusOnNewTerminalsKey)
    }

    static func resolvedMaxLines(_ value: Int) -> Int {
        min(max(value, minimumMaxLines), maximumMaxLines)
    }

    static func maxLines(defaults: UserDefaults = .standard) -> Int {
        guard let value = defaults.object(forKey: maxLinesKey) as? Int else {
            return defaultMaxLines
        }
        return resolvedMaxLines(value)
    }
}

enum TerminalCopyOnSelectSettings {
    static let copyOnSelectKey = "terminal.copyOnSelect"
    static let defaultCopyOnSelect = false
    static let didChangeNotification = Notification.Name("cmux.terminalCopyOnSelectSettingsDidChange")

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        storedValue(defaults: defaults) ?? defaultCopyOnSelect
    }

    static func storedValue(defaults: UserDefaults = .standard) -> Bool? {
        defaults.object(forKey: copyOnSelectKey) as? Bool
    }

    static func ghosttyCopyOnSelectValue(defaults: UserDefaults = .standard) -> String? {
        guard let enabled = storedValue(defaults: defaults) else { return nil }
        return enabled ? "clipboard" : "false"
    }

    static func ghosttyConfigContents(defaults: UserDefaults = .standard) -> String? {
        guard let value = ghosttyCopyOnSelectValue(defaults: defaults) else { return nil }
        return "copy-on-select = \(value)"
    }

    static func setEnabled(
        _ enabled: Bool,
        defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default
    ) {
        let wasEnabled = isEnabled(defaults: defaults)
        defaults.set(enabled, forKey: copyOnSelectKey)
        if wasEnabled != enabled {
            notifyDidChange(notificationCenter: notificationCenter)
        }
    }

    @discardableResult
    static func reset(
        defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default
    ) -> Bool {
        let wasEnabled = isEnabled(defaults: defaults)
        defaults.removeObject(forKey: copyOnSelectKey)
        let didChange = wasEnabled != isEnabled(defaults: defaults)
        if didChange {
            notifyDidChange(notificationCenter: notificationCenter)
        }
        return didChange
    }

    static func notifyDidChange(notificationCenter: NotificationCenter = .default) {
        notificationCenter.post(name: didChangeNotification, object: nil)
    }
}

enum TerminalManagedGhosttySettings {
    static func ghosttyConfigContents(defaults: UserDefaults = .standard) -> String? {
        let lines = [
            TerminalCopyOnSelectSettings.ghosttyConfigContents(defaults: defaults),
        ].compactMap { $0 }
        guard !lines.isEmpty else { return nil }
        return lines.joined(separator: "\n")
    }
}

enum AgentSessionAutoResumeSettings {
    static let autoResumeAgentSessionsKey = "terminal.autoResumeAgentSessions"
    static let defaultAutoResumeAgentSessions = true
    static let didChangeNotification = Notification.Name("cmux.agentSessionAutoResumeSettingsDidChange")

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: autoResumeAgentSessionsKey) != nil else {
            return defaultAutoResumeAgentSessions
        }
        return defaults.bool(forKey: autoResumeAgentSessionsKey)
    }

    static func setEnabled(
        _ enabled: Bool,
        defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default
    ) {
        let wasEnabled = isEnabled(defaults: defaults)
        defaults.set(enabled, forKey: autoResumeAgentSessionsKey)
        if wasEnabled != enabled {
            notifyDidChange(notificationCenter: notificationCenter)
        }
    }

    @discardableResult
    static func reset(
        defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default
    ) -> Bool {
        let wasEnabled = isEnabled(defaults: defaults)
        defaults.removeObject(forKey: autoResumeAgentSessionsKey)
        let didChange = wasEnabled != isEnabled(defaults: defaults)
        if didChange {
            notifyDidChange(notificationCenter: notificationCenter)
        }
        return didChange
    }

    static func notifyDidChange(notificationCenter: NotificationCenter = .default) {
        notificationCenter.post(name: didChangeNotification, object: nil)
    }
}

struct TerminalRegexHighlightRule: Equatable {
    static let defaultBackgroundHex = "#FFE06680"

    let pattern: String
    let backgroundHex: String
}

struct TerminalRegexHighlightRun: Equatable {
    let row: Int
    let column: Int
    let length: Int
    let backgroundHex: String
}

struct TerminalRegexHighlightCompiledRule {
    let pattern: String
    let backgroundHex: String
    let expression: NSRegularExpression

    init?(rule: TerminalRegexHighlightRule) {
        guard let expression = try? NSRegularExpression(pattern: rule.pattern) else {
            return nil
        }
        self.pattern = rule.pattern
        self.backgroundHex = rule.backgroundHex
        self.expression = expression
    }
}

enum TerminalRegexHighlightSettings {
    static let highlightsKey = "terminal.regexHighlights"
    static let defaultHighlights = ""
    static let didChangeNotification = Notification.Name("cmux.terminalRegexHighlightSettingsDidChange")

    private static let runtimeStateLock = NSLock()
    private static var runtimeRawHighlights = rawHighlights()
    private static var runtimeHasRules = hasCompiledRules()
    private static var userDefaultsObserver: NSObjectProtocol?

    static func hasRuntimeRules() -> Bool {
        startObservingUserDefaultsChanges()
        runtimeStateLock.lock()
        defer { runtimeStateLock.unlock() }
        return runtimeHasRules
    }

    static func startObservingUserDefaultsChanges(notificationCenter: NotificationCenter = .default) {
        runtimeStateLock.lock()
        if userDefaultsObserver != nil {
            runtimeStateLock.unlock()
            return
        }
        runtimeStateLock.unlock()

        let observer = notificationCenter.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: nil
        ) { _ in
            synchronizeRuntimeStateIfNeeded()
        }

        runtimeStateLock.lock()
        if userDefaultsObserver == nil {
            userDefaultsObserver = observer
            runtimeStateLock.unlock()
        } else {
            runtimeStateLock.unlock()
            notificationCenter.removeObserver(observer)
        }
    }

    static func rawHighlights(defaults: UserDefaults = .standard) -> String {
        defaults.string(forKey: highlightsKey) ?? defaultHighlights
    }

    static func rules(defaults: UserDefaults = .standard) -> [TerminalRegexHighlightRule] {
        rules(from: rawHighlights(defaults: defaults))
    }

    static func rules(from rawValue: String) -> [TerminalRegexHighlightRule] {
        rawValue
            .split(whereSeparator: \.isNewline)
            .compactMap { line in
                let text = line.trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { return nil }
                if let tabIndex = text.firstIndex(of: "\t") {
                    let color = String(text[..<tabIndex]).trimmingCharacters(in: .whitespaces)
                    let pattern = String(text[text.index(after: tabIndex)...])
                        .trimmingCharacters(in: .whitespaces)
                    guard isSupportedHexColor(color), !pattern.isEmpty else { return nil }
                    return TerminalRegexHighlightRule(
                        pattern: pattern,
                        backgroundHex: normalizedHexColor(color)
                    )
                }
                return TerminalRegexHighlightRule(
                    pattern: text,
                    backgroundHex: TerminalRegexHighlightRule.defaultBackgroundHex
                )
            }
    }

    static func setRawHighlights(
        _ rawValue: String,
        defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default
    ) {
        let previous = rawHighlights(defaults: defaults)
        defaults.set(rawValue, forKey: highlightsKey)
        if previous != rawValue {
            notifyDidChange(defaults: defaults, notificationCenter: notificationCenter)
        }
    }

    @discardableResult
    static func reset(
        defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default
    ) -> Bool {
        let previous = rawHighlights(defaults: defaults)
        defaults.removeObject(forKey: highlightsKey)
        let didChange = previous != rawHighlights(defaults: defaults)
        if didChange {
            notifyDidChange(defaults: defaults, notificationCenter: notificationCenter)
        }
        return didChange
    }

    static func notifyDidChange(
        defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default
    ) {
        updateRuntimeRuleState(rawValue: rawHighlights(defaults: defaults))
        notificationCenter.post(name: didChangeNotification, object: nil)
    }

    @discardableResult
    static func synchronizeRuntimeStateIfNeeded(
        defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default
    ) -> Bool {
        let rawValue = rawHighlights(defaults: defaults)
        runtimeStateLock.lock()
        let didChange = rawValue != runtimeRawHighlights
        runtimeStateLock.unlock()

        guard didChange else { return false }
        updateRuntimeRuleState(rawValue: rawValue)
        notificationCenter.post(name: didChangeNotification, object: nil)
        return true
    }

    private static func updateRuntimeRuleState(rawValue: String) {
        let hasRules = hasCompiledRules(from: rawValue)
        runtimeStateLock.lock()
        runtimeRawHighlights = rawValue
        runtimeHasRules = hasRules
        runtimeStateLock.unlock()
    }

    private static func hasCompiledRules(defaults: UserDefaults = .standard) -> Bool {
        hasCompiledRules(from: rawHighlights(defaults: defaults))
    }

    private static func hasCompiledRules(from rawValue: String) -> Bool {
        !TerminalRegexHighlightMatcher.compiledRules(from: rules(from: rawValue)).isEmpty
    }

    private static func isSupportedHexColor(_ rawValue: String) -> Bool {
        let normalized = normalizedHexColor(rawValue)
        guard normalized.count == 7 || normalized.count == 9 else { return false }
        return normalized.dropFirst().allSatisfy(\.isHexDigit)
    }

    private static func normalizedHexColor(_ rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let withPrefix = trimmed.hasPrefix("#") ? trimmed : "#\(trimmed)"
        return withPrefix.uppercased()
    }
}

enum TerminalRegexHighlightMatcher {
    static let maxRuns = 512

    static func compiledRules(
        from rules: [TerminalRegexHighlightRule]
    ) -> [TerminalRegexHighlightCompiledRule] {
        rules.compactMap(TerminalRegexHighlightCompiledRule.init(rule:))
    }

    static func runs(
        in lines: [String],
        compiledRules: [TerminalRegexHighlightCompiledRule],
        rowOffset: Int = 0,
        maxColumnCount: Int? = nil
    ) -> [TerminalRegexHighlightRun] {
        guard !compiledRules.isEmpty else { return [] }

        var runs: [TerminalRegexHighlightRun] = []
        runs.reserveCapacity(min(32, maxRuns))

        for (lineIndex, line) in lines.enumerated() {
            guard !line.isEmpty else { continue }
            let searchRange = NSRange(line.startIndex..<line.endIndex, in: line)
            for compiledRule in compiledRules {
                var reachedMaxRuns = false
                compiledRule.expression.enumerateMatches(in: line, options: [], range: searchRange) { match, _, stop in
                    guard let match,
                          match.range.length > 0,
                          let range = Range(match.range, in: line) else {
                        return
                    }
                    let column = terminalColumnWidth(line[..<range.lowerBound])
                    let length = terminalColumnWidth(line[range])
                    guard length > 0 else { return }

                    let clippedLength: Int
                    if let maxColumnCount {
                        guard column < maxColumnCount else { return }
                        clippedLength = min(length, maxColumnCount - column)
                    } else {
                        clippedLength = length
                    }
                    guard clippedLength > 0 else { return }

                    runs.append(TerminalRegexHighlightRun(
                        row: rowOffset + lineIndex,
                        column: column,
                        length: clippedLength,
                        backgroundHex: compiledRule.backgroundHex
                    ))
                    if runs.count >= maxRuns {
                        reachedMaxRuns = true
                        stop.pointee = true
                    }
                }
                if reachedMaxRuns {
                    return runs
                }
            }
        }

        return runs
    }

    private static func terminalColumnWidth(_ text: Substring) -> Int {
        text.reduce(0) { total, character in
            total + terminalColumnWidth(for: character)
        }
    }

    private static func terminalColumnWidth(for character: Character) -> Int {
        var hasNonZeroWidthScalar = false
        var hasWideScalar = false
        for scalar in character.unicodeScalars {
            let scalarWidth = terminalColumnWidth(for: scalar)
            guard scalarWidth > 0 else { continue }
            hasNonZeroWidthScalar = true
            if isWideTerminalScalar(scalar.value) {
                hasWideScalar = true
            }
        }
        guard hasNonZeroWidthScalar else { return 0 }
        return hasWideScalar ? 2 : 1
    }

    private static func terminalColumnWidth(for scalar: Unicode.Scalar) -> Int {
        let value = scalar.value
        if value == 0 ||
            value == 0x200D ||
            (0xFE00...0xFE0F).contains(value) {
            return 0
        }

        switch scalar.properties.generalCategory {
        case .control, .enclosingMark, .format, .nonspacingMark:
            return 0
        default:
            break
        }

        return isWideTerminalScalar(value) ? 2 : 1
    }

    private static func isWideTerminalScalar(_ value: UInt32) -> Bool {
        switch value {
        case 0x1100...0x115F,
             0x2329...0x232A,
             0x2E80...0xA4CF,
             0xAC00...0xD7A3,
             0xF900...0xFAFF,
             0xFE10...0xFE19,
             0xFE30...0xFE6F,
             0xFF00...0xFF60,
             0xFFE0...0xFFE6,
             0x1F1E6...0x1F1FF,
             0x1F300...0x1FAFF,
             0x20000...0x3FFFD:
            return true
        default:
            return false
        }
    }
}

enum AgentHibernationSettings {
    struct Values: Equatable, Sendable {
        var enabled: Bool
        var idleSeconds: TimeInterval
        var maxLiveTerminals: Int
        var confirmationSeconds: TimeInterval
    }

    static let enabledKey = "terminal.agentHibernation.enabled"
    static let idleSecondsKey = "terminal.agentHibernation.idleSeconds"
    static let maxLiveTerminalsKey = "terminal.agentHibernation.maxLiveTerminals"
    static let confirmationSecondsKey = "terminal.agentHibernation.confirmationSeconds"

    static let defaultEnabled = false
    // Hibernation is opt-in. Once enabled, reclaim idle background agents quickly:
    // the maxLiveTerminals cap and the confirmationSeconds settle window keep this safe.
    static let defaultIdleSeconds: TimeInterval = 5
    static let defaultMaxLiveTerminals = 12
    static let defaultConfirmationSeconds: TimeInterval = 60
    static let didChangeNotification = Notification.Name("cmux.agentHibernationSettingsDidChange")

    static func values(defaults: UserDefaults = .standard) -> Values {
        Values(
            enabled: isEnabled(defaults: defaults),
            idleSeconds: idleSeconds(defaults: defaults),
            maxLiveTerminals: maxLiveTerminals(defaults: defaults),
            confirmationSeconds: confirmationSeconds(defaults: defaults)
        )
    }

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: enabledKey) != nil else { return defaultEnabled }
        return defaults.bool(forKey: enabledKey)
    }

    static func idleSeconds(defaults: UserDefaults = .standard) -> TimeInterval {
        guard defaults.object(forKey: idleSecondsKey) != nil else { return defaultIdleSeconds }
        return sanitizedIdleSeconds(defaults.double(forKey: idleSecondsKey))
    }

    static func maxLiveTerminals(defaults: UserDefaults = .standard) -> Int {
        guard defaults.object(forKey: maxLiveTerminalsKey) != nil else { return defaultMaxLiveTerminals }
        return sanitizedMaxLiveTerminals(defaults.integer(forKey: maxLiveTerminalsKey))
    }

    static func confirmationSeconds(defaults: UserDefaults = .standard) -> TimeInterval {
        guard defaults.object(forKey: confirmationSecondsKey) != nil else { return defaultConfirmationSeconds }
        return sanitizedConfirmationSeconds(defaults.double(forKey: confirmationSecondsKey))
    }

    static func sanitizedIdleSeconds(_ value: TimeInterval) -> TimeInterval {
        guard value.isFinite else { return defaultIdleSeconds }
        return min(max(value.rounded(), 5), 7 * 24 * 60 * 60)
    }

    static func sanitizedMaxLiveTerminals(_ value: Int) -> Int {
        min(max(value, 1), 256)
    }

    static func sanitizedConfirmationSeconds(_ value: TimeInterval) -> TimeInterval {
        guard value.isFinite else { return defaultConfirmationSeconds }
        return min(max(value.rounded(), 5), 60 * 60)
    }

    static func setValues(
        enabled: Bool? = nil,
        idleSeconds: TimeInterval? = nil,
        maxLiveTerminals: Int? = nil,
        defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default
    ) {
        let oldValues = values(defaults: defaults)
        if let enabled {
            defaults.set(enabled, forKey: enabledKey)
        }
        if let idleSeconds {
            defaults.set(sanitizedIdleSeconds(idleSeconds), forKey: idleSecondsKey)
        }
        if let maxLiveTerminals {
            defaults.set(sanitizedMaxLiveTerminals(maxLiveTerminals), forKey: maxLiveTerminalsKey)
        }
        if oldValues != values(defaults: defaults) {
            notifyDidChange(notificationCenter: notificationCenter)
        }
    }

    @discardableResult
    static func reset(
        defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default
    ) -> Bool {
        let oldValues = values(defaults: defaults)
        defaults.removeObject(forKey: enabledKey)
        defaults.removeObject(forKey: idleSecondsKey)
        defaults.removeObject(forKey: maxLiveTerminalsKey)
        defaults.removeObject(forKey: confirmationSecondsKey)
        let didChange = oldValues != values(defaults: defaults)
        if didChange {
            notifyDidChange(notificationCenter: notificationCenter)
        }
        return didChange
    }

    static func notifyDidChange(notificationCenter: NotificationCenter = .default) {
        notificationCenter.post(name: didChangeNotification, object: nil)
    }
}

enum AgentHibernationTrackingGate {
    private static let lock = NSLock()
    private static var enabled = AgentHibernationSettings.isEnabled()

    static func isEnabled() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return enabled
    }

    static func setEnabled(_ nextEnabled: Bool) {
        lock.lock()
        enabled = nextEnabled
        lock.unlock()
    }
}

enum RightSidebarBetaFeatureSettings {
    static let feedEnabledKey = "rightSidebar.beta.feed.enabled"
    static let dockEnabledKey = "rightSidebar.beta.dock.enabled"

    static let defaultFeedEnabled = false
    static let defaultDockEnabled = false

    nonisolated static func isFeedEnabled(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: feedEnabledKey) != nil else { return defaultFeedEnabled }
        return defaults.bool(forKey: feedEnabledKey)
    }

    nonisolated static func isDockEnabled(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: dockEnabledKey) != nil else { return defaultDockEnabled }
        return defaults.bool(forKey: dockEnabledKey)
    }
}

enum UITestLaunchManifest {
    static let argumentName = "-cmuxUITestLaunchManifest"

    struct Payload: Decodable {
        let environment: [String: String]
    }

    static func applyIfPresent(
        arguments: [String] = CommandLine.arguments,
        loadData: (String) -> Data? = { path in
            try? Data(contentsOf: URL(fileURLWithPath: path))
        },
        applyEnvironment: (String, String) -> Void = { key, value in
            setenv(key, value, 1)
        }
    ) {
        guard let path = manifestPath(from: arguments),
              let data = loadData(path),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            return
        }

        for (key, value) in payload.environment {
            applyEnvironment(key, value)
        }
    }

    static func manifestPath(from arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: argumentName) else { return nil }
        let valueIndex = arguments.index(after: index)
        guard valueIndex < arguments.endIndex else { return nil }

        let rawPath = arguments[valueIndex].trimmingCharacters(in: .whitespacesAndNewlines)
        return rawPath.isEmpty ? nil : rawPath
    }
}
