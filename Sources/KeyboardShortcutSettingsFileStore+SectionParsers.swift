import CmuxSettings
import Foundation

/// Settings-file section parsers for file editor, file explorer, markdown, mobile, and sidebar workspace-todo options, extracted from `KeyboardShortcutSettingsFileStore.swift`, which sits at its file-length budget.
extension CmuxSettingsFileStore {
    func parseFileEditorSection(
        _ section: [String: Any],
        sourcePath: String,
        snapshot: inout ResolvedSettingsSnapshot
    ) {
        if let value = jsonBool(section["wordWrap"]) {
            snapshot.managedUserDefaults[FilePreviewWordWrapSettings.key] = .bool(value)
        } else if section.keys.contains("wordWrap") {
            logInvalid("fileEditor.wordWrap", sourcePath: sourcePath)
        }
    }

    func parseFileExplorerSection(
        _ section: [String: Any],
        sourcePath: String,
        snapshot: inout ResolvedSettingsSnapshot
    ) {
        if let raw = jsonString(section["doubleClickAction"]) {
            if let action = FileExplorerDoubleClickAction(rawValue: raw) {
                snapshot.managedUserDefaults[FileExplorerDoubleClickActionSettings.key] = .string(action.rawValue)
            } else {
                logInvalid("fileExplorer.doubleClickAction", sourcePath: sourcePath)
            }
        } else if section.keys.contains("doubleClickAction") {
            logInvalid("fileExplorer.doubleClickAction", sourcePath: sourcePath)
        }
    }

    func parseSidebarWorkspaceTodosBeta(
        _ beta: [String: Any],
        sourcePath: String,
        snapshot: inout ResolvedSettingsSnapshot
    ) {
        if let rawTodos = beta["workspaceTodos"], let todos = rawTodos as? [String: Any] {
            let betaKeys = BetaFeaturesCatalogSection()
            if let controls = todos["controls"] as? [String: Any] {
                if let enabled = jsonBool(controls["enabled"]) {
                    snapshot.managedUserDefaults[
                        betaKeys.workspaceTodoControls.userDefaultsKey
                    ] = .bool(enabled)
                } else if controls.keys.contains("enabled") {
                    logInvalid("sidebar.beta.workspaceTodos.controls.enabled", sourcePath: sourcePath)
                }
            } else if todos.keys.contains("controls") {
                logInvalid("sidebar.beta.workspaceTodos.controls", sourcePath: sourcePath)
            }
            if let raw = jsonString(todos["checklistStyle"]) {
                if let style = WorkspaceTodoChecklistStyle.decodeFromJSON(raw) {
                    snapshot.managedUserDefaults[
                        betaKeys.workspaceTodosChecklistStyle.userDefaultsKey
                    ] = .string(style.rawValue)
                } else {
                    logInvalid("sidebar.beta.workspaceTodos.checklistStyle", sourcePath: sourcePath)
                }
            } else if todos.keys.contains("checklistStyle") {
                logInvalid("sidebar.beta.workspaceTodos.checklistStyle", sourcePath: sourcePath)
            }
        } else if beta.keys.contains("workspaceTodos") {
            logInvalid("sidebar.beta.workspaceTodos", sourcePath: sourcePath)
        }
    }

    func parseMarkdownSection(
        _ section: [String: Any],
        sourcePath: String,
        snapshot: inout ResolvedSettingsSnapshot
    ) {
        // Accept numeric doubles (e.g. 15 or 15.0) and round to integer points,
        // matching the integer `markdown.fontSize` catalog/UI representation.
        if let value = jsonDouble(section["fontSize"]) {
            if value >= MarkdownFontSizeSettings.minimumPointSize,
               value <= MarkdownFontSizeSettings.maximumPointSize {
                snapshot.managedUserDefaults[MarkdownFontSizeSettings.key] = .int(Int(value.rounded()))
            } else {
                logInvalid("markdown.fontSize", sourcePath: sourcePath)
            }
        } else if section.keys.contains("fontSize") {
            logInvalid("markdown.fontSize", sourcePath: sourcePath)
        }

        if let value = jsonString(section["fontFamily"]) {
            snapshot.managedUserDefaults[MarkdownFontFamily.key] = .string(MarkdownFontFamily.normalized(value))
        } else if section.keys.contains("fontFamily") {
            logInvalid("markdown.fontFamily", sourcePath: sourcePath)
        }

        if let value = jsonDouble(section["maxWidth"]) {
            if value >= MarkdownMaxWidthSettings.minimumCSSPixels,
               value <= MarkdownMaxWidthSettings.maximumCSSPixels {
                snapshot.managedUserDefaults[MarkdownMaxWidthSettings.key] = .int(Int(value.rounded()))
            } else {
                logInvalid("markdown.maxWidth", sourcePath: sourcePath)
            }
        } else if section.keys.contains("maxWidth") {
            logInvalid("markdown.maxWidth", sourcePath: sourcePath)
        }
    }

    func parseMobileSection(
        _ section: [String: Any],
        sourcePath: String,
        snapshot: inout ResolvedSettingsSnapshot
    ) {
        guard section.keys.contains("artifactFolderAccess") else { return }
        guard let raw = jsonString(section["artifactFolderAccess"]),
              let value = MobileArtifactFolderAccess(rawValue: raw) else {
            logInvalid("mobile.artifactFolderAccess", sourcePath: sourcePath)
            return
        }
        let key = SettingCatalog().mobile.artifactFolderAccess
        snapshot.managedUserDefaults[key.userDefaultsKey] = .string(value.rawValue)
    }
}
