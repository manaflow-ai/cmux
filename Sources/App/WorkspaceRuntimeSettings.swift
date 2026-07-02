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
    static let submitActionsKey = "terminal.textBoxSubmitActions"
    static let defaultSubmitActionKey = "terminal.textBoxDefaultSubmitAction"
    static let defaultSubmitActionID = TextBoxSubmitAction.textEntryAction.id

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
    /// Returns the Ghostty `copy-on-select` value; `emitsFalse: false` lets Ghostty config/defaults remain authoritative.
    static func ghosttyCopyOnSelectValue(defaults: UserDefaults = .standard, emitsFalse: Bool = true) -> String? {
        guard let enabled = storedValue(defaults: defaults) else { return nil }
        return enabled ? "clipboard" : (emitsFalse ? "false" : nil)
    }

    static func ghosttyConfigContents(defaults: UserDefaults = .standard, emitsFalse: Bool = true) -> String? {
        guard let value = ghosttyCopyOnSelectValue(defaults: defaults, emitsFalse: emitsFalse) else { return nil }
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
    static func ghosttyConfigContents(defaults: UserDefaults = .standard, emitsCopyOnSelectFalse: Bool = true) -> String? {
        let lines = [
            TerminalCopyOnSelectSettings.ghosttyConfigContents(defaults: defaults, emitsFalse: emitsCopyOnSelectFalse),
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

/// Settings for non-destructive offscreen renderer reclamation. Unlike
/// `AgentHibernationSettings` (which kills a resumable agent's PTY and is opt-in),
/// this only releases an offscreen terminal's GPU renderer (Metal swap chain /
/// IOSurface) while keeping its PTY and terminal state alive, rebuilding it on
/// re-show. It is therefore safe to default ON. The cap keeps recently-used tabs
/// warm so switching stays instant; the idle window avoids reclaiming a tab the
/// user just left.
enum RendererRealizationSettings {
    struct Values: Equatable, Sendable {
        var enabled: Bool
        var idleSeconds: TimeInterval
        var maxWarmRenderers: Int
    }

    static let enabledKey = "terminal.rendererRealization.enabled"
    static let idleSecondsKey = "terminal.rendererRealization.idleSeconds"
    static let maxWarmRenderersKey = "terminal.rendererRealization.maxWarmRenderers"

    static let defaultEnabled = true
    static let defaultIdleSeconds: TimeInterval = 30
    static let defaultMaxWarmRenderers = 12
    static let didChangeNotification = Notification.Name("cmux.rendererRealizationSettingsDidChange")

    static func values(defaults: UserDefaults = .standard) -> Values {
        Values(
            enabled: isEnabled(defaults: defaults),
            idleSeconds: idleSeconds(defaults: defaults),
            maxWarmRenderers: maxWarmRenderers(defaults: defaults)
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

    static func maxWarmRenderers(defaults: UserDefaults = .standard) -> Int {
        guard defaults.object(forKey: maxWarmRenderersKey) != nil else { return defaultMaxWarmRenderers }
        return sanitizedMaxWarmRenderers(defaults.integer(forKey: maxWarmRenderersKey))
    }

    static func sanitizedIdleSeconds(_ value: TimeInterval) -> TimeInterval {
        guard value.isFinite else { return defaultIdleSeconds }
        return min(max(value.rounded(), 5), 7 * 24 * 60 * 60)
    }

    static func sanitizedMaxWarmRenderers(_ value: Int) -> Int {
        min(max(value, 1), 256)
    }

    static func setValues(
        enabled: Bool? = nil,
        idleSeconds: TimeInterval? = nil,
        maxWarmRenderers: Int? = nil,
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
        if let maxWarmRenderers {
            defaults.set(sanitizedMaxWarmRenderers(maxWarmRenderers), forKey: maxWarmRenderersKey)
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
        defaults.removeObject(forKey: maxWarmRenderersKey)
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
    static let notesEnabledKey = "rightSidebar.beta.notes.enabled"
    static let feedEnabledKey = "rightSidebar.beta.feed.enabled"
    static let dockEnabledKey = "rightSidebar.beta.dock.enabled"

    static let defaultNotesEnabled = false
    static let defaultFeedEnabled = false
    static let defaultDockEnabled = false

    nonisolated static func isNotesEnabled(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: notesEnabledKey) != nil else { return defaultNotesEnabled }
        return defaults.bool(forKey: notesEnabledKey)
    }

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
