import AppKit
import CmuxNextDesign
import CmuxNextActions
import CmuxNextBrowser
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
        let guide = PasswordCSVGuide(presenter: LivePasswordCSVGuidePresenter(queries: services.workspaceQueries))
        // main-hop-allow: the action's tracked work awaits the person's own guide sheets and open panel (main-actor AppKit UI), then the file's import
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
        // Conflicts are held for Replace only when this fork can replace them (API 20).
        let hold = cef.canReplacePasswords ? PasswordConflictHold { rows, profile in try await cef.replacePasswords(rows, in: profile) } : nil
        let destination = AppPasswordDestination(available: true, hold: hold) { rows, profile in
            try await cef.importPasswords(rows, into: profile)
        }
        do {
            let report = try await run(PasswordCSVImporter(destination: destination, work: services.work))
            // The app window, not the key window: after the cmux picker that is the palette's panel.
            let windows = services.windows
            Self.trash(url, report: report, hold: hold) { windows.active?.window ?? NSApp.keyWindow ?? NSApp.mainWindow }
            return nil
        } catch PasswordCSVImporter.Failure.cancelled {
            hold?.release()
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

    /// The prefix of every password CSV toast's id.
    static let toastID = "password-csv-imported"

    /// One toast per file (the prefix and a hash of its path), so a second import's toast stands
    /// beside the first file's offer instead of replacing it (cx-dwg.8).
    static func fileToastID(_ url: URL) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325 // FNV-1a: stable across launches, unlike Hasher
        for byte in url.standardizedFileURL.path.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        return "\(toastID)-\(String(hash, radix: 16))"
    }

    /// The counts, and the file's fate: it holds every password in plain
    /// text, so when every row is in the store (or was there already) it goes
    /// to the Trash now and the toast's Undo puts it back. When some rows did
    /// not go in (a conflict keeps the saved password, a rejected row), the
    /// file may be the only copy: it stays and the toast offers Move to Trash,
    /// as it does when the move fails. Conflicts the `hold` kept are offered
    /// for Replace first (cx-dwg.6).
    static func trash(_ url: URL, report: PasswordImportReport, hold: PasswordConflictHold? = nil,
                      windowLookup: @escaping @MainActor () -> NSWindow? = { NSApp.keyWindow ?? NSApp.mainWindow }) {
        let summary = summaryLines(report)
        guard let window = windowLookup() else {
            hold?.release()
            logger.info("password CSV import done with no window; the file stays")
            return
        }
        if let hold, hold.count > 0 {
            return offerReplace(url, summary, hold, othersMissing: report.store.rejected, in: window, windowLookup: windowLookup)
        }
        guard report.store.conflict + report.store.rejected == 0 else { return offerTrash(url, summary, in: window) }
        recycle(url, summary, windowLookup: windowLookup)
    }

    /// Never overwritten silently: the saved passwords stay unless the person
    /// presses Replace. Then the file goes to the Trash when every row is in
    /// the store; otherwise, or when the toast goes without Replace, it offers
    /// Move to Trash.
    private static func offerReplace(_ url: URL, _ summary: [String], _ hold: PasswordConflictHold, othersMissing: Int,
                                     in window: NSWindow, windowLookup: @escaping @MainActor () -> NSWindow?) {
        let toast = CmuxToast(id: fileToastID(url), message: summary.joined(separator: " "),
                              action: CmuxToast.Action(title: PasswordCSVStrings.replace), duration: .seconds(20))
        let handle = CmuxToastCenter.shared.show(toast, in: window)
        handle.onAction = {
            // main-hop-allow: the person's Replace click; the task only awaits the hold's main-actor store writes and shows their result in that resume
            Task { @MainActor in
                let replaced: ChromiumPasswordReplaceResult
                do {
                    replaced = try await hold.replace()
                } catch {
                    logger.error("password CSV replace failed: \(String(describing: error), privacy: .public)")
                    guard let window = windowLookup() else { return }
                    return offerTrash(url, [PasswordCSVStrings.replaceFailed], in: window)
                }
                let lines = [PasswordCSVStrings.replaced(replaced.updated)]
                guard othersMissing + replaced.missing + replaced.rejected == 0 else {
                    guard let window = windowLookup() else { return }
                    return offerTrash(url, lines, in: window)
                }
                recycle(url, lines, windowLookup: windowLookup)
            }
        }
        handle.onDismiss = { reason in
            guard reason != .action else { return }
            hold.release()
            // After the toast center ends this one (a dismiss can come from inside its show).
            // main-hop-allow: the toast center's own order: a dismiss from inside its show must not show a toast re-entrantly, so the offer waits one job
            Task { @MainActor in
                guard let window = windowLookup() else { return }
                // A newer toast for this file took the slot and says what happened next; other
                // files' toasts and unrelated ones that pushed this one out do not.
                if reason == .replaced, CmuxToastCenter.shared.toasts(in: window).contains(where: { $0.id == fileToastID(url) }) { return }
                offerTrash(url, summary, in: window)
            }
        }
    }

    /// Moves the file to the Trash; the toast's Undo puts it back.
    private static func recycle(_ url: URL, _ summary: [String], windowLookup: @escaping @MainActor () -> NSWindow?) {
        NSWorkspace.shared.recycle([url]) { @Sendable moved, error in
            // main-hop-allow: NSWorkspace calls back on a thread of its own; the hop only shows the toast in one main job
            Task { @MainActor in
                // Looked up again on the main actor: a window is not Sendable.
                guard let window = windowLookup() else { return }
                guard error == nil, let trashed = moved[url] else { return offerTrash(url, summary, in: window) }
                let toast = CmuxToast(id: fileToastID(url), message: (summary + [PasswordCSVStrings.trashed]).joined(separator: " "),
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
        let toast = CmuxToast(id: fileToastID(url), message: (summary + [PasswordCSVStrings.plaintextWarning]).joined(separator: " "),
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
    static var replace: String { t("passwords.csv.replace", "Replace Saved Passwords") }
    static func replaced(_ count: Int) -> String {
        String(format: t("passwords.csv.replaced", "Replaced: %lld."), count)
    }
    static var replaceFailed: String {
        t("passwords.csv.replaceFailed", "The saved passwords couldn’t be replaced. cmux kept them.")
    }
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
