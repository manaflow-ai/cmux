import AppKit
import CmuxNextDesign
import CmuxNextActions
import CmuxNextBrowserImport
import Foundation
import UniformTypeIdentifiers

/// Import Passwords from CSV… (`password.importCSV`): the person picks the
/// file in an open panel, which is the confirmation; there is no path
/// argument, and the action is person-only, so the control socket cannot
/// open the panel for a file an agent staged. The passwords go into
/// the browser profile's Chromium password store, counts only come back, and
/// the dialog offers to move the plaintext file to the Trash
/// (plans/cmux-next/browser.md, "Browser import: passwords and security").
@MainActor
struct PasswordCSVFiles {
    let services: AppServices

    func chooseImport(profile: String) throws {
        guard let cef = services.cache?.cef else { throw ActionFailure(message: PasswordCSVStrings.unavailable) }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.allowsMultipleSelection = false
        panel.message = PasswordCSVStrings.prompt
        panel.beginForCmux { url in
            guard let url else { return }
            services.registry.track(Task { @MainActor in
                guard await cef.canImportPasswords() else { return ActionWorkFailure(PasswordCSVStrings.unavailable) }
                let destination = AppPasswordDestination(available: true) { rows, profile in try await cef.importPasswords(rows, into: profile) }
                do {
                    let report = try await PasswordCSVImporter(destination: destination).run(file: url, intoProfile: profile)
                    Self.offerTrash(url, report: report)
                    return nil
                } catch {
                    return ActionWorkFailure(PasswordCSVStrings.failure(error))
                }
            })
        }
    }

    /// The counts, and the file's fate: it still holds every password in plain text.
    static func offerTrash(_ url: URL, report: PasswordImportReport) {
        let spec = CmuxDialogSpec(
            title: PasswordCSVStrings.doneTitle,
            lines: [PasswordCSVStrings.counts(imported: report.imported, notImported: report.notImported), PasswordCSVStrings.plaintextWarning],
            buttons: [CmuxDialogButton(id: "keep", title: PasswordCSVStrings.keepFile, role: .cancel),
                      CmuxDialogButton(id: "trash", title: PasswordCSVStrings.moveToTrash, role: .default)],
            identifier: "cmux.dialog.passwordCSV.trash")
        let scope: CmuxDialogScope = (NSApp.keyWindow ?? NSApp.mainWindow).map { .window($0) } ?? .app
        CmuxDialogCenter.shared.present(spec, in: scope) { answer in
            if answer.button == "trash" { NSWorkspace.shared.recycle([url]) }
        }
    }
}

enum PasswordCSVStrings {
    private static func t(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, table: "Passwords", bundle: .module)
    }

    static var prompt: String { t("passwords.csv.prompt", "Choose a password CSV exported from a browser or password manager.") }
    static var doneTitle: String { t("passwords.csv.done", "Passwords Imported") }
    static func counts(imported: Int, notImported: Int) -> String {
        String(format: t("passwords.csv.counts", "Imported: %1$lld. Not imported: %2$lld (already saved, repeated, or not a website sign-in)."),
               imported, notImported)
    }
    static var plaintextWarning: String {
        t("passwords.csv.plaintext", "The CSV file still holds these passwords in plain text. Move it to the Trash?")
    }
    static var moveToTrash: String { t("passwords.csv.trash", "Move to Trash") }
    static var keepFile: String { t("passwords.csv.keep", "Keep File") }
    static var unavailable: String { t("passwords.csv.unavailable", "This version of cmux can’t save passwords yet.") }

    static func failure(_ error: any Error) -> String {
        switch error as? PasswordCSVImporter.Failure {
        case .storeUnavailable: unavailable
        case .unreadable: t("passwords.csv.unreadable", "The file couldn’t be read.")
        case .noPasswordColumns: t("passwords.csv.noColumns", "The file has no website and password columns.")
        case nil: t("passwords.csv.failed", "The passwords couldn’t be saved.")
        }
    }
}
