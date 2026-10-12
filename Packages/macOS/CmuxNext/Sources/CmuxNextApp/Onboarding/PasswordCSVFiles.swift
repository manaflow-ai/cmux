import AppKit
import CmuxNextDesign
import CmuxNextActions
import CmuxNextBrowserImport
import Foundation
import UniformTypeIdentifiers
import os

/// Import Passwords from CSV… (`password.importCSV`): the person says where
/// the passwords are (Safari / Apple Passwords, 1Password and Bitwarden get
/// their export steps first) and picks the file in an open panel, which is
/// the confirmation; there is no path
/// argument, and the action is person-only, so the control socket cannot
/// open the panel for a file an agent staged. The passwords go into
/// the browser profile's Chromium password store, counts only come back, and
/// the plaintext file goes to the Trash at once when every row went in, with
/// Undo in the toast
/// (Lawrence 2026-10-07: no confirm dialogs; plans/cmux-next/browser.md,
/// "Browser import: passwords and security").
@MainActor
struct PasswordCSVFiles {
    let services: AppServices

    /// The guided steps (source, the source's export steps, the open panel), then the import of
    /// the picked file and its move to the Trash.
    func chooseImport(profile: String) throws {
        let guide = PasswordCSVGuide(presenter: LivePasswordCSVGuidePresenter())
        services.registry.track(Task { @MainActor in
            guard let url = await guide.run() else { return nil }
            return await importFile(url, profile: profile)
        })
    }

    /// Imports a CSV the person picked, then moves it to the Trash; the failure, if any.
    func importFile(_ url: URL, profile: String) async -> ActionWorkFailure? {
        // A header with no known website or password column: the person matches the columns by name.
        let name = url.lastPathComponent
        return await importCSV(trashing: url, profile: profile) {
            try await $0.run(file: url, intoProfile: profile) { header in await PasswordCSVColumnSheet.choose(header, fileName: name) }
        }
    }

    /// Imports a CSV from an export archive, then moves the archive (`file`) to the Trash.
    func importBytes(_ bytes: SecretBytes, profile: String, trashing file: URL) async -> ActionWorkFailure? {
        await importCSV(trashing: file, profile: profile) { try await $0.run(bytes: bytes, intoProfile: profile) }
    }

    private func importCSV(trashing url: URL, profile: String,
                           run: (PasswordCSVImporter) async throws -> PasswordImportReport) async -> ActionWorkFailure? {
        let cef = services.cache.cef
        guard await cef.canImportPasswords() else { return ActionWorkFailure(PasswordCSVStrings.unavailable) }
        let destination = AppPasswordDestination(available: true) { rows, profile in try await cef.importPasswords(rows, into: profile) }
        do {
            let report = try await run(PasswordCSVImporter(destination: destination))
            // The app window, not the key window: after the cmux picker that is the palette's panel.
            let windows = services.windows
            Self.trash(url, report: report) { windows.active?.window ?? NSApp.keyWindow ?? NSApp.mainWindow }
            return nil
        } catch PasswordCSVImporter.Failure.cancelled {
            return nil
        } catch {
            return ActionWorkFailure(PasswordCSVStrings.failure(error))
        }
    }

    /// Counts only. Sign-ins saved with another password get their own line:
    /// cmux kept the saved password, and the person should know they differ.
    static func summaryLines(_ report: PasswordImportReport) -> [String] {
        var lines = [PasswordCSVStrings.counts(imported: report.imported, notImported: report.notImportedOtherThanConflicts)]
        if report.conflicts > 0 { lines.append(PasswordCSVStrings.conflicts(report.conflicts)) }
        return lines
    }

    static let toastID = "password-csv-imported"

    /// The counts, and the file's fate: it holds every password in plain
    /// text, so when every row is in the store (or was there already) it goes
    /// to the Trash now and the toast's Undo puts it back. When some rows did
    /// not go in (a conflict keeps the saved password, a rejected row), the
    /// file may be the only copy: it stays and the toast offers Move to Trash,
    /// as it does when the move fails.
    static func trash(_ url: URL, report: PasswordImportReport,
                      windowLookup: @escaping @MainActor () -> NSWindow? = { NSApp.keyWindow ?? NSApp.mainWindow }) {
        let summary = summaryLines(report)
        guard let window = windowLookup() else {
            logger.info("password CSV import done with no window; the file stays")
            return
        }
        guard report.store.conflict + report.store.rejected == 0 else { return offerTrash(url, summary, in: window) }
        NSWorkspace.shared.recycle([url]) { @Sendable moved, error in
            Task { @MainActor in
                // Looked up again on the main actor: a window is not Sendable.
                guard let window = windowLookup() else { return }
                guard error == nil, let trashed = moved[url] else { return offerTrash(url, summary, in: window) }
                let toast = CmuxToast(id: toastID, message: (summary + [PasswordCSVStrings.trashed]).joined(separator: " "),
                                      action: .undo(), duration: .seconds(12))
                CmuxToastCenter.shared.show(toast, in: window).onAction = {
                    do { try FileManager.default.moveItem(at: trashed, to: url) } catch {
                        logger.error("password CSV put back failed: \(String(describing: error), privacy: .public)")
                    }
                }
            }
        }
    }

    private static func offerTrash(_ url: URL, _ summary: [String], in window: NSWindow) {
        let toast = CmuxToast(id: toastID, message: (summary + [PasswordCSVStrings.plaintextWarning]).joined(separator: " "),
                              action: CmuxToast.Action(title: PasswordCSVStrings.moveToTrash), duration: .seconds(20))
        CmuxToastCenter.shared.show(toast, in: window).onAction = { NSWorkspace.shared.recycle([url]) }
    }

    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "passwords.csv")
}

enum PasswordCSVStrings {
    private static func t(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, table: "Passwords", bundle: .module)
    }

    static var prompt: String { t("passwords.csv.prompt", "Choose a password CSV exported from a browser or password manager.") }
    static func counts(imported: Int, notImported: Int) -> String {
        String(format: t("passwords.csv.counts", "Imported: %1$lld. Not imported: %2$lld (already saved, repeated, or not a website sign-in)."),
               imported, notImported)
    }
    static func conflicts(_ count: Int) -> String {
        String(format: t("passwords.csv.conflicts", "Already saved with a different password: %lld. cmux kept the saved password."), count)
    }
    static var plaintextWarning: String {
        t("passwords.csv.plaintext", "The CSV file still holds these passwords in plain text. Move it to the Trash?")
    }
    static var moveToTrash: String { t("passwords.csv.trash", "Move to Trash") }
    static var trashed: String { t("passwords.csv.trashed", "The CSV file is in the Trash.") }
    static var unavailable: String { t("passwords.csv.unavailable", "This version of cmux can’t save passwords yet.") }

    static func failure(_ error: any Error) -> String {
        switch error as? PasswordCSVImporter.Failure {
        case .storeUnavailable: unavailable
        case .unreadable: t("passwords.csv.unreadable", "The file couldn’t be read.")
        case .noPasswordColumns: t("passwords.csv.noColumns", "The file has no website and password columns.")
        case .cancelled: t("passwords.csv.failed", "The passwords couldn’t be saved.")
        case nil: t("passwords.csv.failed", "The passwords couldn’t be saved.")
        }
    }
}
