import Foundation

/// Layout template strings (table MiscHandlers.xcstrings).
enum LayoutTemplateStrings {
    private static func t(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, table: "MiscHandlers", bundle: .module)
    }

    static var nameRequired: String { t("handlers.layoutTemplate.nameRequired", "A layout template needs a name") }
    static var templateRequired: String { t("handlers.layoutTemplate.templateRequired", "Choose a layout template") }
    static var noTemplates: String { t("handlers.layoutTemplate.noTemplates", "No layout templates yet. Save a workspace’s layout as a template first.") }
    static func noTemplate(_ name: String) -> String {
        String(format: t("handlers.layoutTemplate.noTemplate", "No layout template named “%@”"), name)
    }
    static func nameTaken(_ name: String) -> String {
        String(format: t("handlers.layoutTemplate.nameTaken", "Another layout template is named “%@”"), name)
    }
    static var manageTitle: String { t("handlers.layoutTemplate.manageTitle", "Layout Templates") }
    static var managePlaceholder: String { t("handlers.layoutTemplate.managePlaceholder", "Search layout templates") }
    static var newWorkspace: String { t("handlers.layoutTemplate.newWorkspace", "New Workspace from Template") }
    static var rename: String { t("handlers.layoutTemplate.rename", "Rename…") }
    static var delete: String { t("handlers.layoutTemplate.delete", "Delete") }
    static var renameTitle: String { t("handlers.layoutTemplate.renameTitle", "Rename Layout Template") }
    static var namePlaceholder: String { t("handlers.layoutTemplate.namePlaceholder", "Template name") }
    static func renameTo(_ name: String) -> String {
        String(format: t("handlers.layoutTemplate.renameTo", "Rename to “%@”"), name)
    }
    static func panes(_ count: Int) -> String {
        String(format: t("handlers.layoutTemplate.panes", "Panes: %lld"), count)
    }
}
