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

    static func unreadable(_ name: String) -> String {
        String(format: t("import.files.unreadable", "“%@” couldn’t be read."), name)
    }
    static func historyImported(_ count: Int) -> String {
        String(format: t("import.files.historyImported", "Pages of history imported: %lld."), count)
    }

    /// The passwords, bookmarks and history steps of `source`, each one line.
    static func steps(_ source: BrowserExportSource) -> [String] {
        exportSteps(source) + historySteps(source)
    }

    private static func historySteps(_ source: BrowserExportSource) -> [String] {
        if source.family == .safari {
            return [t("import.files.safari.archive",
                      "Or everything at once (Safari 18 or later): choose File > Export Browsing Data to File…, then choose the zip file.")]
        }
        guard let takeout = source.history else { return [] }
        return [String(format: t("import.files.chromium.history",
                                 "History: export %1$@ at %2$@ (Google Takeout), then choose the zip or its History.json file."),
                       source.name, takeout)]
    }

    private static func exportSteps(_ source: BrowserExportSource) -> [String] {
        switch source.family {
        case .chromium:
            [String(format: t("import.files.chromium.passwords",
                              "Passwords: in %1$@, open %2$@, click Download File next to Export Passwords, then save the CSV file."),
                    source.name, source.passwords ?? "")]
                + (source.bookmarks.map {
                    [String(format: t("import.files.chromium.bookmarks",
                                      "Bookmarks: in %1$@, open %2$@, open the ⋮ menu, choose Export Bookmarks, then save the HTML file."),
                            source.name, $0)]
                } ?? [])
        case .firefox:
            [t("import.files.firefox.passwords",
               "Passwords: in Firefox, open about:logins, open the ⋯ menu, choose Export Passwords…, then save the CSV file."),
             t("import.files.firefox.bookmarks",
               "Bookmarks: in Firefox, choose Bookmarks > Manage Bookmarks, then Import and Backup > Export Bookmarks to HTML…")]
        case .safari:
            [t("import.files.safari.passwords",
               "Passwords: in the Passwords app, choose File > Export All Passwords to File… (on macOS 14 or earlier, in Safari: File > Export > Passwords…)."),
             t("import.files.safari.bookmarks", "Bookmarks: in Safari, choose File > Export > Bookmarks…, then save the HTML file.")]
        // The password managers: the guided CSV import's export steps, without its last "choose it here" step.
        case .onePassword: Array(PasswordCSVGuideStrings.steps(.onePassword).dropLast())
        case .bitwarden: Array(PasswordCSVGuideStrings.steps(.bitwarden).dropLast())
        }
    }
}
