import Foundation

/// Strings of Import from Another Browser… (table Passwords).
nonisolated enum BrowserFileImportStrings {
    private static func t(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, table: "Passwords", bundle: .module)
    }

    static var title: String { t("import.files.title", "Import from Another Browser") }
    static var message: String {
        t("import.files.message", "cmux imports the files a browser exports: passwords as a CSV file, bookmarks as an HTML file. Which browser are they in?")
    }
    static var browserLabel: String { t("import.files.browser", "Browser:") }
    static func stepsTitle(_ browser: String) -> String {
        String(format: t("import.files.stepsTitle", "Export from %@"), browser)
    }
    static var chooseFiles: String { t("import.files.chooseFiles", "Choose Files…") }
    static var lastStep: String {
        t("import.files.lastStep", "Then choose the exported files here. You can choose both at once.")
    }
    static var pickerTitle: String { t("import.files.pickerTitle", "Import from Another Browser") }
    static func notAnExport(_ name: String) -> String {
        String(format: t("import.files.notAnExport", "“%@” is not a password CSV or bookmarks HTML file."), name)
    }

    /// The passwords and bookmarks steps of `source`, each one line.
    static func steps(_ source: BrowserExportSource) -> [String] {
        switch source.family {
        case .chromium:
            [String(format: t("import.files.chromium.passwords",
                              "Passwords: in %1$@, open %2$@, click Download File next to Export Passwords, then save the CSV file."),
                    source.name, source.passwords ?? ""),
             String(format: t("import.files.chromium.bookmarks",
                              "Bookmarks: in %1$@, open %2$@, open the ⋮ menu, choose Export Bookmarks, then save the HTML file."),
                    source.name, source.bookmarks ?? "")]
        case .firefox:
            [t("import.files.firefox.passwords",
               "Passwords: in Firefox, open about:logins, open the ⋯ menu, choose Export Passwords…, then save the CSV file."),
             t("import.files.firefox.bookmarks",
               "Bookmarks: in Firefox, choose Bookmarks > Manage Bookmarks, then Import and Backup > Export Bookmarks to HTML…")]
        case .safari:
            [t("import.files.safari.passwords",
               "Passwords: in the Passwords app, choose File > Export All Passwords to File… (on macOS 14 or earlier, in Safari: File > Export > Passwords…)."),
             t("import.files.safari.bookmarks", "Bookmarks: in Safari, choose File > Export > Bookmarks…, then save the HTML file.")]
        }
    }
}
