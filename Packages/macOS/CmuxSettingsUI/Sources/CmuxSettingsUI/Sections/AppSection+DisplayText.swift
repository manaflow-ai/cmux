import CmuxSettings
import Foundation

@MainActor
extension AppSection {
    func languageDisplayName(_ language: AppLanguage) -> String {
        // Mirrors legacy AppLanguage.displayName: native name plus an
        // English suffix in parentheses, except for English and
        // Portuguese (Brasil) which already carry the locale name.
        switch language {
        case .system: return String(localized: "language.system", defaultValue: "System")
        case .en: return "English"
        case .ar: return "\u{200E}العربية (Arabic)"
        case .bs: return "Bosanski (Bosnian)"
        case .zhHans: return "简体中文 (Chinese Simplified)"
        case .zhHant: return "繁體中文 (Chinese Traditional)"
        case .da: return "Dansk (Danish)"
        case .de: return "Deutsch (German)"
        case .es: return "Español (Spanish)"
        case .fr: return "Français (French)"
        case .it: return "Italiano (Italian)"
        case .ja: return "日本語 (Japanese)"
        case .ko: return "한국어 (Korean)"
        case .nb: return "Norsk (Norwegian)"
        case .pl: return "Polski (Polish)"
        case .ptBR: return "Português (Brasil)"
        case .ru: return "Русский (Russian)"
        case .th: return "ไทย (Thai)"
        case .tr: return "Türkçe (Turkish)"
        case .vi: return "Tiếng Việt (Vietnamese)"
        }
    }

    func workspacePlacementSubtitle(_ placement: WorkspacePlacement) -> String {
        // Mirrors legacy NewWorkspacePlacement.description verbatim
        // (Sources/TabManager.swift, "workspace.placement.*.description").
        switch placement {
        case .top:
            return String(
                localized: "workspace.placement.top.description",
                defaultValue: "Insert new workspaces at the top of the list."
            )
        case .afterCurrent:
            return String(
                localized: "workspace.placement.afterCurrent.description",
                defaultValue: "Insert new workspaces directly after the active workspace."
            )
        case .end:
            return String(
                localized: "workspace.placement.end.description",
                defaultValue: "Append new workspaces to the bottom of the list."
            )
        }
    }

    func fileDropSubtitle(_ behavior: FileDropDefaultBehavior) -> String {
        switch behavior {
        case .text:
            return String(
                localized: "settings.app.fileDrop.defaultBehavior.text.subtitle",
                defaultValue: "Over terminals and editors, dragging files inserts shell-escaped paths. Hold Shift to open a file preview or split."
            )
        case .preview:
            return String(
                localized: "settings.app.fileDrop.defaultBehavior.preview.subtitle",
                defaultValue: "Dragging files opens previews or split panes. Hold Shift over terminals and editors to insert path text."
            )
        }
    }

    func confirmQuitSubtitle(_ mode: ConfirmQuitMode) -> String {
        // Mirrors legacy confirmQuitModeSubtitle keys/text.
        switch mode {
        case .always: return String(localized: "settings.app.warnBeforeQuit.subtitleOn", defaultValue: "Show a confirmation before quitting with Cmd+Q.")
        case .dirtyOnly: return String(localized: "settings.app.confirmQuit.subtitleDirtyOnly", defaultValue: "Show a confirmation only when a workspace needs close confirmation.")
        case .never: return String(localized: "settings.app.warnBeforeQuit.subtitleOff", defaultValue: "Cmd+Q quits immediately without confirmation.")
        }
    }

    func warnCloseXSubtitle(hideCloseButton: Bool, warnEnabled: Bool) -> String {
        // Mirrors legacy warnBeforeClosingTabXButtonSubtitle: hidden override
        // takes priority, then on/off wording.
        if hideCloseButton {
            return String(
                localized: "settings.app.warnBeforeClosingTabXButton.subtitleHidden",
                defaultValue: "Tab close buttons are hidden, so this warning is inactive."
            )
        }
        if warnEnabled {
            return String(
                localized: "settings.app.warnBeforeClosingTabXButton.subtitleOn",
                defaultValue: "The tab close button asks for confirmation before closing."
            )
        }
        return String(
            localized: "settings.app.warnBeforeClosingTabXButton.subtitleOff",
            defaultValue: "The tab close button closes tabs immediately."
        )
    }
}
