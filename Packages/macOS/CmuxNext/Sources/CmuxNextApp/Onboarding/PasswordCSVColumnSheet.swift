import AppKit
import CmuxNextBrowserImport
import CmuxNextDesign
import Foundation

/// The column sheet (cx-d0d.65): a password CSV whose header names no website
/// or password column that cmux knows. The person matches the website,
/// username and password columns by the header's names; the sheet shows those
/// names and the row count only, never a value (``PasswordCSVHeader`` refuses
/// a first row that looks like a sign-in).
@MainActor
enum PasswordCSVColumnSheet {
    private static let url = "url", username = "username", password = "password", none = "none"

    /// The person's match, or nil when they cancelled.
    static func choose(_ header: PasswordCSVHeader, fileName: String) async -> PasswordCSVColumns? {
        let options = header.names.enumerated().map { index, name in
            CmuxDialogOption(label: name.isEmpty ? PasswordCSVColumnStrings.unnamed(index + 1) : name, value: String(index))
        }
        let guess = guess(header.names)
        let spec = CmuxDialogSpec(
            title: PasswordCSVColumnStrings.title,
            lines: [PasswordCSVColumnStrings.message(fileName, rows: header.rows)],
            fields: [
                .choice(id: url, label: PasswordCSVColumnStrings.website, options: options, selected: String(guess.url)),
                .choice(id: username, label: PasswordCSVColumnStrings.username,
                        options: [CmuxDialogOption(label: PasswordCSVColumnStrings.none, value: none)] + options,
                        selected: guess.username.map(String.init) ?? none),
                .choice(id: password, label: PasswordCSVColumnStrings.password, options: options, selected: String(guess.password)),
            ],
            buttons: [CmuxDialogButton(id: "cancel", title: PasswordCSVGuideStrings.cancel, role: .cancel),
                      CmuxDialogButton(id: "import", title: PasswordCSVColumnStrings.importTitle, role: .default)],
            identifier: "cmux.dialog.passwordCSV.columns")
        let scope: CmuxDialogScope = (NSApp.mainWindow ?? NSApp.keyWindow).map { .window($0) } ?? .app
        let answer = await CmuxDialogCenter.shared.present(spec, in: scope)
        guard answer.button == "import", !answer.isDismissal,
              let urlColumn = answer.text(url).flatMap(Int.init), let passwordColumn = answer.text(password).flatMap(Int.init)
        else { return nil }
        return PasswordCSVColumns(url: urlColumn, username: answer.text(username).flatMap(Int.init), password: passwordColumn)
    }

    /// A first choice by name (a column named like "Site", "Login", "Secret"), else the first columns in order.
    static func guess(_ names: [String]) -> PasswordCSVColumns {
        let lower = names.map { $0.lowercased() }
        func first(_ words: [String], not taken: [Int?] = []) -> Int? {
            lower.indices.first { index in !taken.contains(index) && words.contains { lower[index].contains($0) } }
        }
        let password = first(["pass", "secret", "pwd", "key"]) ?? min(2, names.count - 1)
        let url = first(["url", "site", "web", "link", "address", "domain", "host", "uri"], not: [password])
            ?? names.indices.first { $0 != password } ?? 0
        let username = first(["user", "login", "mail", "account", "name"], not: [password, url])
        return PasswordCSVColumns(url: url, username: username, password: password)
    }
}

/// Strings of the column sheet (table Passwords).
nonisolated enum PasswordCSVColumnStrings {
    private static func t(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, table: "Passwords", bundle: .module)
    }

    static var title: String { t("passwords.csv.columns.title", "Match the Columns") }
    static func message(_ file: String, rows: Int) -> String {
        String(format: t("passwords.csv.columns.message",
                         "cmux doesn’t know the columns of “%1$@” (rows: %2$lld). Choose the column that holds each part."),
               file, rows)
    }
    static var website: String { t("passwords.csv.columns.website", "Website:") }
    static var username: String { t("passwords.csv.columns.username", "Username:") }
    static var password: String { t("passwords.csv.columns.password", "Password:") }
    static var none: String { t("passwords.csv.columns.none", "None") }
    static var importTitle: String { t("passwords.csv.columns.import", "Import") }
    static func unnamed(_ number: Int) -> String {
        String(format: t("passwords.csv.columns.unnamed", "Column %lld"), number)
    }
}
