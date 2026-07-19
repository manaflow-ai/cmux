import CmuxSettings
import Foundation

/// Settings-file section parsers for file editor, file explorer, and sidebar workspace-todo options, extracted from `KeyboardShortcutSettingsFileStore.swift`, which sits at its file-length budget.
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
}
