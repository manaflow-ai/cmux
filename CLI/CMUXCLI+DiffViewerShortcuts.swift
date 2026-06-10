import Darwin
import Foundation


// MARK: - Diff Viewer Keyboard Shortcuts
extension CMUXCLI {
    func diffViewerShortcutPayload() -> [String: Any] {
        Dictionary(
            uniqueKeysWithValues: diffViewerShortcuts().map { action, shortcut in
                (action.rawValue, shortcut.jsonObject)
            }
        )
    }

    private func diffViewerShortcuts() -> [DiffViewerShortcutAction: DiffViewerShortcut] {
        var shortcuts = Dictionary(
            uniqueKeysWithValues: DiffViewerShortcutAction.allCases.map { action in
                (action, action.defaultShortcut)
            }
        )
        var managedActions = Set<DiffViewerShortcutAction>()

        for path in diffViewerShortcutSettingsPaths() {
            guard let settings = diffViewerShortcutSettings(at: path) else { continue }
            for (action, shortcut) in settings where !managedActions.contains(action) {
                shortcuts[action] = shortcut
                managedActions.insert(action)
            }
        }

        let primaryPath = Self.absoluteDiffViewerSettingsPath(Self.primarySettingsDisplayPath)
        if let settings = diffViewerShortcutSettings(at: primaryPath) {
            for (action, shortcut) in settings {
                shortcuts[action] = shortcut
                managedActions.insert(action)
            }
        }

        return shortcuts
    }

    private func diffViewerShortcutSettingsPaths() -> [String] {
        [
            Self.legacySettingsDisplayPath,
            Self.fallbackSettingsDisplayPath,
        ].map(Self.absoluteDiffViewerSettingsPath)
    }

    private func diffViewerShortcutSettings(at path: String) -> [DiffViewerShortcutAction: DiffViewerShortcut]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              !data.isEmpty,
              let sanitized = try? JSONCParser.preprocess(data: data),
              let root = try? JSONSerialization.jsonObject(with: sanitized) as? [String: Any],
              let shortcutsSection = root["shortcuts"] as? [String: Any] else {
            return nil
        }

        var rawBindings = shortcutsSection["bindings"] as? [String: Any] ?? [:]
        for (key, rawValue) in shortcutsSection where key != "bindings" && key != "showModifierHoldHints" {
            rawBindings[key] = rawValue
        }

        var bindings: [DiffViewerShortcutAction: DiffViewerShortcut] = [:]
        for action in DiffViewerShortcutAction.allCases {
            guard let rawBinding = rawBindings[action.rawValue],
                  let shortcut = Self.parseDiffViewerShortcut(rawBinding) else {
                continue
            }
            bindings[action] = shortcut
        }
        return bindings
    }

    private static func parseDiffViewerShortcut(_ rawValue: Any) -> DiffViewerShortcut? {
        if rawValue is NSNull {
            return .unbound
        }
        if let rawString = rawValue as? String {
            return parseDiffViewerShortcut(strokes: [rawString])
        }
        if let rawStrings = rawValue as? [String] {
            return rawStrings.isEmpty ? .unbound : parseDiffViewerShortcut(strokes: rawStrings)
        }
        return nil
    }

    private static func parseDiffViewerShortcut(strokes: [String]) -> DiffViewerShortcut? {
        guard !strokes.isEmpty, strokes.count <= 2 else { return nil }
        if strokes.count == 1, isUnboundDiffViewerShortcutToken(strokes[0]) {
            return .unbound
        }
        let parsed = strokes.compactMap(parseDiffViewerShortcutStroke)
        guard parsed.count == strokes.count, let first = parsed.first else { return nil }
        return DiffViewerShortcut(
            first: first,
            second: parsed.count == 2 ? parsed[1] : nil
        )
    }

    private static func parseDiffViewerShortcutStroke(_ rawValue: String) -> DiffViewerShortcutStroke? {
        let rawParts = rawValue.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        let parts = rawParts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let lastRawPart = rawParts.last, !lastRawPart.isEmpty else { return nil }

        var command = false
        var shift = false
        var option = false
        var control = false
        for modifier in parts.dropLast() {
            switch modifier.lowercased() {
            case "cmd", "command", "⌘":
                command = true
            case "shift", "⇧":
                shift = true
            case "opt", "option", "alt", "⌥":
                option = true
            case "ctrl", "control", "ctl", "⌃":
                control = true
            default:
                return nil
            }
        }

        guard let key = parseDiffViewerShortcutKeyToken(lastRawPart) else { return nil }
        return DiffViewerShortcutStroke(key: key, command: command, shift: shift, option: option, control: control)
    }

    private static func parseDiffViewerShortcutKeyToken(_ rawValue: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return rawValue == " " ? "space" : nil
        }

        switch trimmed.lowercased() {
        case "space", "spacebar", "<space>":
            return "space"
        case "slash":
            return "/"
        case "period", "dot":
            return "."
        case "comma":
            return ","
        default:
            guard trimmed.count == 1 else { return nil }
            return trimmed.lowercased()
        }
    }

    private static func isUnboundDiffViewerShortcutToken(_ rawValue: String) -> Bool {
        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "", "none", "clear", "unbound", "disabled":
            return true
        default:
            return false
        }
    }

    static func absoluteDiffViewerSettingsPath(_ rawPath: String) -> String {
        let homePath = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        let expanded: String
        if rawPath == "~" {
            expanded = homePath
        } else if rawPath.hasPrefix("~/") {
            expanded = (homePath as NSString).appendingPathComponent(String(rawPath.dropFirst(2)))
        } else {
            expanded = rawPath
        }
        let absolute = (expanded as NSString).isAbsolutePath
            ? expanded
            : (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent(expanded)
        return URL(fileURLWithPath: absolute).standardizedFileURL.path
    }

}
