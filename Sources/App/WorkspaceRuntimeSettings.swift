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
            notifyDidChange(notificationCenter: notificationCenter)
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
            notifyDidChange(notificationCenter: notificationCenter)
        }
        return didChange
    }

    static func notifyDidChange(notificationCenter: NotificationCenter = .default) {
        notificationCenter.post(name: didChangeNotification, object: nil)
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
                for match in compiledRule.expression.matches(in: line, range: searchRange) {
                    guard match.range.length > 0,
                          let range = Range(match.range, in: line) else {
                        continue
                    }
                    let column = terminalColumnWidth(line[..<range.lowerBound])
                    let length = terminalColumnWidth(line[range])
                    guard length > 0 else { continue }

                    let clippedLength: Int
                    if let maxColumnCount {
                        guard column < maxColumnCount else { continue }
                        clippedLength = min(length, maxColumnCount - column)
                    } else {
                        clippedLength = length
                    }
                    guard clippedLength > 0 else { continue }

                    runs.append(TerminalRegexHighlightRun(
                        row: rowOffset + lineIndex,
                        column: column,
                        length: clippedLength,
                        backgroundHex: compiledRule.backgroundHex
                    ))
                    if runs.count >= maxRuns {
                        return runs
                    }
                }
            }
        }

        return runs
    }

    private static func terminalColumnWidth(_ text: Substring) -> Int {
        text.unicodeScalars.reduce(0) { total, scalar in
            total + terminalColumnWidth(for: scalar)
        }
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
             0x1F300...0x1FAFF,
             0x20000...0x3FFFD:
            return true
        default:
            return false
        }
    }
}

enum RightSidebarBetaFeatureSettings {
    static let dockEnabledKey = "rightSidebar.beta.dock.enabled"

    static let defaultDockEnabled = false

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
